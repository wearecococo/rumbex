#![allow(non_local_definitions)]
use rustler::{Env, NifResult, ResourceArc, Term, Encoder, Atom, Binary, NifMap};
use rustler::types::binary::OwnedBinary;

use std::{
    convert::TryInto,
    io::{Read, Write},
    str::FromStr,
    sync::Mutex,
};

use smb::{
    client::{Client, ClientConfig, UncPath},
    packets::{
        fscc::{
            FileAccessMask,
            FileAttributes,
            common_info::FileBasicInformation,
            query_file_info::FileStandardInformation,
            set_file_info::FileRenameInformation2,
            directory_info::FileIdFullDirectoryInformation,
        },
        binrw_util::{
            sized_wide_string::SizedWideString,
            helpers::Boolean,
        },
        smb2::{CreateOptions, CreateDisposition},
        
    },
    resource::{
        file::File as SmbFile,
        directory::Directory,
        FileCreateArgs,
        Resource
    },
};

// Client is held in Mutex — Client methods require &mut self
struct Conn {
    client: Mutex<Client>,
    share: UncPath, // \\host\share
}

#[derive(NifMap)]
struct RichStats {
    r#type: Atom,            // :file | :directory
    size: u64,               // EndOfFile
    allocation_size: u64,    // AllocationSize
    nlink: u32,              // NumberOfLinks
    attributes: u32,         // FILE_ATTRIBUTE_* bitmask (LE)
    mtime: u64,              // LastWriteTime -> unix seconds
    atime: u64,              // LastAccessTime -> unix seconds
    ctime: u64,              // ChangeTime -> unix seconds
    btime: u64,              // CreationTime -> unix seconds
}

mod atoms {
    rustler::atoms! { ok, error, file, directory, not_found}
}

// SMB/NTSTATUS — most needed
const STATUS_OBJECT_NAME_NOT_FOUND: u32 = 0xC0000034;
const STATUS_DELETE_PENDING:       u32 = 0xC0000056;
const STATUS_DIRECTORY_NOT_EMPTY:  u32 = 0xC0000101;
 
// ==================== Helpers ====================
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
enum Kind { File, Dir }

fn open_for_kind(client: &mut smb::Client, unc: &UncPath) -> Option<Kind> {
    let access = FileAccessMask::new().with_generic_read(true);
    let mut args = FileCreateArgs::make_open_existing(access);

    // Try as file
    args.options = CreateOptions::default(); // by default "not directory"
    if let Ok(res) = smb::client::Client::create_file(client, unc, &args) {
        let out = match res {
            smb::resource::Resource::File(_)      => Some(Kind::File),
            smb::resource::Resource::Directory(_) => Some(Kind::Dir),
            _ => None,
        };
        drop(res);
        return out;
    }
    None
}

fn ntstatus_from_err_display<E: std::fmt::Display>(e: &E) -> Option<u32> {
    let s = e.to_string();
    let start = s.find("(0x")?;
    let hex   = &s[start+3..].trim_end_matches(')');
    u32::from_str_radix(hex, 16).ok()
}

// FILETIME (100ns ticks since 1601-01-01) -> Unix seconds (>=0; 0 if unknown)
fn filetime_to_unix_seconds(ticks: u64) -> u64 {
    if ticks == 0 { return 0; }
    // 10_000_000 ticks = 1 second; delta between 1601-01-01 and 1970-01-01:
    const EPOCH_DELTA: u64 = 11_644_473_600;
    let secs = ticks / 10_000_000;
    secs.saturating_sub(EPOCH_DELTA)
}
    
// ==================== NIFs ====================
#[rustler::nif(schedule = "DirtyIo")]
fn connect<'a>(
    env: Env<'a>,
    unc_share: String,
    username: String,
    password: String,
) -> NifResult<Term<'a>> {
    // expect string like "\\\\host\\share"
    let share = UncPath::from_str(&unc_share)
        .map_err(|e| rustler::Error::Term(Box::new(format!("bad_unc: {e}"))))?;

    let mut client = Client::new(ClientConfig::default());
    client
        .share_connect(&share, &username, password)
        .map_err(|e| rustler::Error::Term(Box::new(format!("connect_error: {e}"))))?;

    let res = ResourceArc::new(Conn {
        client: Mutex::new(client),
        share,
    });

    Ok((atoms::ok(), res).encode(env))
}

#[rustler::nif(schedule = "DirtyIo")]
fn read_file<'a>(
    env: Env<'a>,
    conn: ResourceArc<Conn>,
    path_in_share: String,
) -> NifResult<Term<'a>> {
    let rel = path_in_share.trim_start_matches(['\\', '/']);
    let base = conn.share.to_string();
    let full = if rel.is_empty() { base } else { format!(r"{}\{}", base.trim_end_matches('\\'), rel) };

    let file_unc = UncPath::from_str(&full).map_err(|_| rustler::Error::BadArg)?;

    let mut client = conn.client.lock().map_err(|_| rustler::Error::Term(Box::new("mutex_poisoned")))?;
    let access = FileAccessMask::new().with_generic_read(true);
    let args = FileCreateArgs::make_open_existing(access);

    let resource: Resource = client
        .create_file(&file_unc, &args)
        .map_err(|e| rustler::Error::Term(Box::new(format!("smb_open_failed: {e}"))))?;

    drop(client);

    let mut file: SmbFile = resource
        .try_into()
        .map_err(|_| rustler::Error::Term(Box::new("not_a_file")))?;

    let mut buf = Vec::new();
    file.read_to_end(&mut buf)
        .map_err(|e| rustler::Error::Term(Box::new(format!("smb_read_failed: {e}"))))?;

    let mut obin = OwnedBinary::new(buf.len())
        .ok_or_else(|| rustler::Error::Term(Box::new("alloc_failed")))?;
    obin.as_mut_slice().copy_from_slice(&buf);
    let bin_term = obin.release(env);

    Ok((atoms::ok(), bin_term).encode(env))
}

#[rustler::nif(schedule = "DirtyIo")]
fn write_file<'a>(
    env: Env<'a>,
    conn: ResourceArc<Conn>,
    path_in_share: String,
    data: Binary<'a>,
) -> NifResult<Term<'a>> {
    let rel = path_in_share.trim_start_matches(['\\', '/']);
    let base = conn.share.to_string();
    let full = if rel.is_empty() { base } else { format!(r"{}\{}", base.trim_end_matches('\\'), rel) };

    let file_unc = UncPath::from_str(&full).map_err(|_| rustler::Error::BadArg)?;

    let mut client = conn.client.lock().map_err(|_| rustler::Error::Term(Box::new("mutex_poisoned")))?;

    // overwrite/create with RW access
    let mut args = FileCreateArgs::make_overwrite(FileAttributes::default(), CreateOptions::default());
    args.desired_access = FileAccessMask::new().with_generic_read(true).with_generic_write(true);

    let resource: Resource = client
        .create_file(&file_unc, &args)
        .map_err(|e| rustler::Error::Term(Box::new(format!("smb_create_failed: {e}"))))?;

    drop(client);

    let mut file: SmbFile = resource
        .try_into()
        .map_err(|_| rustler::Error::Term(Box::new("not_a_file")))?;

    file.write_all(data.as_slice())
        .map_err(|e| rustler::Error::Term(Box::new(format!("smb_write_failed: {e}"))))?;

    Ok(atoms::ok().encode(env))
}

#[rustler::nif(schedule = "DirtyIo")]
fn list_dir<'a>(
    env: Env<'a>,
    conn: ResourceArc<Conn>,
    path_in_share: String,
) -> NifResult<Term<'a>> {
    // relative path inside share
    let rel = path_in_share.trim_matches(['\\', '/']);
    let base = conn.share.to_string();
    let full = if rel.is_empty() {
        base
    } else {
        format!(r"{}\{}", base.trim_end_matches('\\'), rel)
    };
    let dir_unc = UncPath::from_str(&full).map_err(|_| rustler::Error::BadArg)?;

    // open directory descriptor
    let mut client = conn
        .client
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("mutex_poisoned")))?;
    let access = FileAccessMask::new().with_generic_read(true);
    let args = FileCreateArgs::make_open_existing(access);

    let res: Resource = client
        .create_file(&dir_unc, &args)
        .map_err(|e| rustler::Error::Term(Box::new(format!("smb_open_failed: {e}"))))?;

    drop(client); // client no longer needed

    // convert to Directory
    let dir: Directory = res
        .try_into()
        .map_err(|_| rustler::Error::Term(Box::new("not_a_directory")))?;

    // read list, use class without short_name
    let iter = dir
        .query_directory::<FileIdFullDirectoryInformation>("*")
        .map_err(|e| rustler::Error::Term(Box::new(format!("query_failed: {e}"))))?;

    let mut out: Vec<(String, Atom)> = Vec::new();

    for item in iter {
        match item {
            Ok(info) => {
                let name = info.file_name.to_string();
                if name == "." || name == ".." {
                    continue;
                }
                let kind = if info.file_attributes.directory() {
                    atoms::directory()
                } else {
                    atoms::file()
                };
                out.push((name, kind));
            }
            Err(_e) => {
                // sometimes corrupted records are encountered — just skip them
                continue;
            }
        }
    }

    Ok((atoms::ok(), out).encode(env))
}

#[rustler::nif(schedule = "DirtyIo")]
fn stat<'a>(
    env: Env<'a>,
    conn: ResourceArc<Conn>,
    path_in_share: String,
) -> NifResult<Term<'a>> {
    // relative path inside share (without leading \ or /)
    let rel = path_in_share.trim_start_matches(['\\', '/']);

    // build full UNC: "\\host\share\rel"
    let base = conn.share.to_string();
    let full = if rel.is_empty() {
        base
    } else {
        format!(r"{}\{}", base.trim_end_matches('\\'), rel)
    };

    let unc = UncPath::from_str(&full).map_err(|_| rustler::Error::BadArg)?;

    // get client
    let mut client = conn
        .client
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("mutex_poisoned")))?;

    // open resource for reading
    let args = FileCreateArgs::make_open_existing(
        FileAccessMask::new().with_generic_read(true),
    );

    let res: Resource = client
        .create_file(&unc, &args)
        .map_err(|e| rustler::Error::Term(Box::new(format!("smb_open_failed: {e}"))))?;

    // Try to treat as file
    if let Ok(mut file) = <Resource as TryInto<SmbFile>>::try_into(res) {
        // read entirely, size = buffer length
        let mut buf = Vec::new();
        file.read_to_end(&mut buf)
            .map_err(|e| rustler::Error::Term(Box::new(format!("smb_read_failed: {e}"))))?;
        let size = buf.len() as u64;
        return Ok((atoms::ok(), (size, false)).encode(env));
    }

    // Otherwise consider it a directory (for share root this is also ok)
    Ok((atoms::ok(), (0u64, true)).encode(env))
}

#[rustler::nif(schedule = "DirtyIo")]
fn mkdir_p<'a>(
    env: Env<'a>,
    conn: ResourceArc<Conn>,
    rel_path: String,
) -> NifResult<Term<'a>> {
    // Normalize relative path inside share
    let rel = rel_path
        .trim_start_matches(['\\', '/'])
        .trim_end_matches(['\\', '/']);

    if rel.is_empty() {
        return Ok(atoms::ok().encode(env));
    }

    let mut client = conn
        .client
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("mutex_poisoned")))?;

    // Build path by segments: \\host\share\seg1 -> ...\seg1\seg2 -> ...
    let mut acc = conn.share.to_string();

    for seg in rel.split(|c| c == '\\' || c == '/') {
        if seg.is_empty() || seg == "." {
            continue;
        }
        if seg == ".." {
            return Err(rustler::Error::Term(Box::new("bad_segment: '..'")));
        }

        acc = format!(r"{}\{}", acc.trim_end_matches('\\'), seg);
        let unc = UncPath::from_str(&acc).map_err(|_| rustler::Error::BadArg)?;

        // Access and flags for creating directory (create-if-not-exists)
        let access = FileAccessMask::new()
            .with_generic_read(true)
            .with_generic_write(true);
        let attrs = FileAttributes::default().with_directory(true);
        let opts  = CreateOptions::default().with_directory_file(true);

        let mut args = FileCreateArgs::make_create_new(attrs, opts);
        args.disposition = CreateDisposition::OpenIf;
        args.desired_access = access;

        client
            .create_file(&unc, &args)
            .map_err(|e| rustler::Error::Term(Box::new(format!("mkdir_failed: {e}"))))?;
    }

    Ok(atoms::ok().encode(env))
}

#[rustler::nif(schedule = "DirtyIo")]
fn mkdir<'a>(
    env: Env<'a>,
    conn: ResourceArc<Conn>,
    rel_path: String,
) -> NifResult<Term<'a>> {
    // Trim leading/trailing slashes
    let rel = rel_path.trim_matches(['\\', '/']);

    if rel.is_empty() {
        return Err(rustler::Error::Term(Box::new("bad_path")));
    }

    // Full UNC directory
    let full = format!(r"{}\{}", conn.share.to_string().trim_end_matches('\\'), rel);
    let unc  = UncPath::from_str(&full).map_err(|_| rustler::Error::BadArg)?;

    // Open client
    let mut client = conn
        .client
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("mutex_poisoned")))?;

    // Flags: create ONLY if doesn't exist; without OpenIf
    let access = FileAccessMask::new()
    .with_generic_read(true)
    .with_generic_write(true);
    let attrs = FileAttributes::default().with_directory(true);
    let opts  = CreateOptions::default().with_directory_file(true);

    let mut args = FileCreateArgs::make_create_new(attrs, opts);
    args.desired_access = access; // <- using access, warning will disappear

    match client.create_file(&unc, &args) {
        Ok(_res) => Ok(atoms::ok().encode(env)),
        Err(e) => Err(rustler::Error::Term(Box::new(format!("mkdir_failed: {e}")))),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn exists<'a>(
    env: Env<'a>,
    conn: ResourceArc<Conn>,
    path_in_share: String,
) -> NifResult<Term<'a>> {
    let rel = path_in_share.trim_matches(['\\', '/']);
    if rel.is_empty() {
        return Ok((atoms::ok(), atoms::directory()).encode(env));
    }

    let full = format!(r"{}\{}", conn.share.to_string().trim_end_matches('\\'), rel);
    let unc  = UncPath::from_str(&full).map_err(|_| rustler::Error::BadArg)?;

    let mut guard = conn.client.lock()
        .map_err(|_| rustler::Error::Term(Box::new("mutex_poisoned")))?;

    let out = match open_for_kind(&mut *guard, &unc) {
        Some(Kind::File) => atoms::file(),
        Some(Kind::Dir)  => atoms::directory(),
        None             => atoms::not_found(),
    };
    Ok((atoms::ok(), out).encode(env))
}

#[rustler::nif(schedule = "DirtyIo")]
fn rm<'a>(
    env: Env<'a>,
    conn: ResourceArc<Conn>,
    path_in_share: String,
) -> NifResult<Term<'a>> {
    let rel = path_in_share.trim_matches(['\\', '/']);
    if rel.is_empty() {
        return Err(rustler::Error::Term(Box::new("bad_path")));
    }

    // Full UNC
    let full = format!(r"{}\{}", conn.share.to_string().trim_end_matches('\\'), rel);
    let unc  = UncPath::from_str(&full).map_err(|_| rustler::Error::BadArg)?;

    // Get client
    let mut client = conn
        .client
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("mutex_poisoned")))?;

    // Determine type (file/directory); if already gone — success
    let kind = match open_for_kind(&mut *client, &unc) {
        Some(k) => k,
        None    => return Ok(atoms::ok().encode(env)),
    };

    // Open with DELETE and DELETE_ON_CLOSE
    let access = FileAccessMask::new()
        .with_delete(true)
        .with_generic_read(true)
        .with_generic_write(true);

    let mut args = FileCreateArgs::make_open_existing(access);
    let mut opts = CreateOptions::default().with_delete_on_close(true);
    if matches!(kind, Kind::Dir) {
        opts = opts.with_directory_file(true);
    } else {
        opts = opts.with_non_directory_file(true);
    }
    args.options = opts;

    match smb::client::Client::create_file(&mut *client, &unc, &args) {
        Ok(handle) => {
            // Handle acquired — object will be deleted on close. Return success without waiting.
            drop(handle);
            Ok(atoms::ok().encode(env))
        }
        Err(e) => {
            // Parse NTSTATUS code from error text
            match ntstatus_from_err_display(&e) {
                Some(STATUS_OBJECT_NAME_NOT_FOUND) |
                Some(STATUS_DELETE_PENDING) => {
                    // Already deleted or marked for deletion — consider success
                    Ok(atoms::ok().encode(env))
                }
                Some(STATUS_DIRECTORY_NOT_EMPTY) => {
                    Err(rustler::Error::Term(Box::new("dir_not_empty")))
                }
                _ => Err(rustler::Error::Term(Box::new(format!("rm_failed: {e}")))),
            }
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn file_stats<'a>(
    env: Env<'a>,
    conn: ResourceArc<Conn>,
    path_in_share: String,
) -> NifResult<Term<'a>> {
    // Build full UNC
    let rel = path_in_share.trim_matches(['\\', '/']);
    let full = if rel.is_empty() {
        conn.share.to_string()
    } else {
        format!(r"{}\{}", conn.share.to_string().trim_end_matches('\\'), rel)
    };
    let unc = UncPath::from_str(&full).map_err(|_| rustler::Error::BadArg)?;

    // Get client and determine resource type
    let mut client = conn
        .client
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("mutex_poisoned")))?;

    let kind = match open_for_kind(&mut *client, &unc) {
        Some(k) => k,
        None => {
            // Object doesn't exist
            return Ok((atoms::ok(), atoms::not_found()).encode(env));
        }
    };

    // Open handle with READ. For directory set directory_file(true).
    let access = FileAccessMask::new().with_generic_read(true);
    let mut args = FileCreateArgs::make_open_existing(access);
    args.options = match kind {
        Kind::Dir => CreateOptions::default().with_directory_file(true),
        Kind::File => CreateOptions::default().with_non_directory_file(true),
    };

    let res: Resource = client
        .create_file(&unc, &args)
        .map_err(|e| rustler::Error::Term(Box::new(format!("smb_open_failed: {e}"))))?;

    drop(client);

    // Unified get FileBasicInformation + FileStandardInformation
    // depending on type (both File and Directory support query_info via Deref<ResourceHandle>)
    let (size, alloc, nlink, attrs_bits, mtime, atime, ctime, btime) = match kind {
        Kind::File => {
            let file: SmbFile = res
                .try_into()
                .map_err(|_| rustler::Error::Term(Box::new("not_a_file")))?;
            let basic: FileBasicInformation = file
                .query_info()
                .map_err(|e| rustler::Error::Term(Box::new(format!("query_basic_failed: {e}"))))?;
            let stdi: FileStandardInformation = file
                .query_info()
                .map_err(|e| rustler::Error::Term(Box::new(format!("query_standard_failed: {e}"))))?;

            let attrs_bits: u32 = u32::from_le_bytes(basic.file_attributes.into_bytes());
            let mtime = filetime_to_unix_seconds(*basic.last_write_time);
            let atime = filetime_to_unix_seconds(*basic.last_access_time);
            let ctime = filetime_to_unix_seconds(*basic.change_time);
            let btime = filetime_to_unix_seconds(*basic.creation_time);

            (stdi.end_of_file, stdi.allocation_size, stdi.number_of_links, attrs_bits, mtime, atime, ctime, btime)
        }
        Kind::Dir => {
            let dir: Directory = res
                .try_into()
                .map_err(|_| rustler::Error::Term(Box::new("not_a_directory")))?;
            let basic: FileBasicInformation = dir
                .query_info()
                .map_err(|e| rustler::Error::Term(Box::new(format!("query_basic_failed: {e}"))))?;
            let stdi: FileStandardInformation = dir
                .query_info()
                .map_err(|e| rustler::Error::Term(Box::new(format!("query_standard_failed: {e}"))))?;

            let attrs_bits: u32 = u32::from_le_bytes(basic.file_attributes.into_bytes());
            let mtime = filetime_to_unix_seconds(*basic.last_write_time);
            let atime = filetime_to_unix_seconds(*basic.last_access_time);
            let ctime = filetime_to_unix_seconds(*basic.change_time);
            let btime = filetime_to_unix_seconds(*basic.creation_time);

            (stdi.end_of_file, stdi.allocation_size, stdi.number_of_links, attrs_bits, mtime, atime, ctime, btime)
        }
    };

    // Build map -> {:ok, map}
    let out = RichStats {
        r#type: match kind { Kind::File => atoms::file(), Kind::Dir => atoms::directory() },
        size,
        allocation_size: alloc,
        nlink,
        attributes: attrs_bits,
        mtime,
        atime,
        ctime,
        btime,
    };

    Ok((atoms::ok(), out).encode(env))
}

#[rustler::nif(schedule = "DirtyIo")]
fn rename<'a>(
    env: Env<'a>,
    conn: ResourceArc<Conn>,
    from_in_share: String,
    to_in_share: String,
    replace_if_exists: bool,
) -> NifResult<Term<'a>> {
    let from_rel = from_in_share.trim_matches(['\\', '/']);
    let to_rel   = to_in_share.trim_matches(['\\', '/']);
    if from_rel.is_empty() || to_rel.is_empty() {
        return Err(rustler::Error::Term(Box::new("bad_path")));
    }

    // Build full UNC
    let base = conn.share.to_string();
    let from_unc = format!(r"{}\{}", base.trim_end_matches('\\'), from_rel);
    
    // Full RELATIVE destination path for file_name (share-relative)
    // SMB expects backslashes:
    let to_rel_bs = to_rel.replace('/', "\\");
    let file_name: SizedWideString = to_rel_bs.as_str().into();

    // Open source object to call set_file_info
    let mut client = conn.client
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("mutex_poisoned")))?;

    let access = FileAccessMask::new()
        .with_delete(true)
        .with_generic_read(true)
        .with_generic_write(true);

    let mut args = FileCreateArgs::make_open_existing(access);
    // Don't know in advance if it's a file or directory — first try as file
    let from_unc = UncPath::from_str(&from_unc).map_err(|_| rustler::Error::BadArg)?;

    let info = FileRenameInformation2 {
        replace_if_exists: Boolean::from(replace_if_exists), // or: replace_if_exists.into()
        root_directory: 0u64,                                // absolute rename
        file_name,
    };

    // 1) try as file
    args.options = CreateOptions::default().with_non_directory_file(true);
    if let Ok(res) = client.create_file(&from_unc, &args) {
        let file: SmbFile = res
            .try_into()
            .map_err(|_| rustler::Error::Term(Box::new("not_a_file_or_dir")))?;
        file.set_file_info(info)
            .map_err(|e| rustler::Error::Term(Box::new(format!("rename_failed: {e}"))))?;

        return Ok(atoms::ok().encode(env));
    }

    // 2) otherwise as directory
    args.options = CreateOptions::default().with_directory_file(true);
    let res = client
        .create_file(&from_unc, &args)
        .map_err(|e| rustler::Error::Term(Box::new(format!("open_failed: {e}"))))?;
    
    let dir: Directory = res
        .try_into()
        .map_err(|_| rustler::Error::Term(Box::new("not_a_directory")))?;
    dir.set_file_info(info)
        .map_err(|e| rustler::Error::Term(Box::new(format!("rename_failed: {e}"))))?;

    Ok(atoms::ok().encode(env))
}

// ==================== on_load & init ====================

fn on_load(env: Env, _info: Term) -> bool {
    let _ty = rustler::resource!(Conn, env);
    true
}

rustler::init!(
    "Elixir.Rumbex.Native",
    load = on_load
);
