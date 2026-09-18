//! Private PostgreSQL backup worker. Credentials arrive on stdin, never argv.
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::os::unix::{ffi::OsStrExt, process::CommandExt};
use std::{
    collections::{HashMap, HashSet},
    fs::{self, File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write},
    path::{Component, Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    thread,
    time::{Duration, Instant},
};
use zip::{write::SimpleFileOptions, CompressionMethod, ZipArchive, ZipWriter};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Deserialize)]
struct Config {
    operation: String,
    format: String,
    mode: Option<String>,
    ownership: Option<String>,
    owner: String,
    database: String,
    server_version: String,
    host: String,
    port: u16,
    username: String,
    password: String,
    ssl_mode: String,
    ssl_root_cert: String,
    directory: PathBuf,
    root: PathBuf,
    max_bytes: u64,
    quota_bytes: u64,
    timeout: u64,
    tools: HashMap<String, Option<String>>,
}
struct Context {
    config: Config,
    stopped: Arc<AtomicBool>,
    deadline: Instant,
    last_check: Instant,
}
impl Context {
    fn check(&mut self, force: bool) -> Result<()> {
        if self.stopped.load(Ordering::Relaxed) {
            return Err(
                "Operation cancelled. Check the destination if a restore was in progress.".into(),
            );
        }
        if Instant::now() > self.deadline {
            return Err("Operation exceeded the configured time limit.".into());
        }
        if force || self.last_check.elapsed() > Duration::from_secs(2) {
            self.last_check = Instant::now();
            fn size(path: &Path, work: &Path, limit: u64) -> Result<u64> {
                let mut total = 0;
                for entry in fs::read_dir(path)? {
                    let entry = entry?;
                    let info = fs::symlink_metadata(entry.path())?;
                    if info.is_file() {
                        if path == work && info.len() > limit {
                            return Err("Backup exceeds the configured file size limit.".into());
                        }
                        total += info.len();
                    } else if info.is_dir() {
                        total += size(&entry.path(), work, limit)?;
                    }
                }
                Ok(total)
            }
            if size(
                &self.config.root,
                &self.config.directory,
                self.config.max_bytes,
            )? > self.config.quota_bytes
            {
                return Err("Backup storage quota reached.".into());
            }
            let root = std::ffi::CString::new(self.config.root.as_os_str().as_bytes())?;
            let mut stat = std::mem::MaybeUninit::<libc::statvfs>::uninit();
            if unsafe { libc::statvfs(root.as_ptr(), stat.as_mut_ptr()) } != 0 {
                return Err(io::Error::last_os_error().into());
            }
            let stat = unsafe { stat.assume_init() };
            if stat.f_bavail as u64 * (stat.f_frsize as u64) < 64 * 1024 * 1024 {
                return Err("Less than 64 MiB free on the backup filesystem.".into());
            }
        }
        Ok(())
    }
    fn tool(&self, name: &str) -> Result<String> {
        self.config
            .tools
            .get(name)
            .and_then(|v| v.clone())
            .ok_or_else(|| format!("Missing executable {name}").into())
    }
    fn connection(&self) -> String {
        fn quote(value: &str) -> String {
            format!("'{}'", value.replace('\\', "\\\\").replace('\'', "\\'"))
        }
        format!(
            "host={} port={} dbname={} user={} connect_timeout=10",
            quote(&self.config.host),
            self.config.port,
            quote(&self.config.database),
            quote(&self.config.username)
        )
    }
    fn command(&mut self, arguments: &[String]) -> Result<()> {
        self.check(false)?;
        let mut cmd = Command::new(&arguments[0]);
        cmd.args(&arguments[1..])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0);
        for (name, _) in std::env::vars_os() {
            if name.to_string_lossy().starts_with("PG") {
                cmd.env_remove(name);
            }
        }
        cmd.env("PGPASSWORD", &self.config.password)
            .env("PGSSLMODE", &self.config.ssl_mode)
            .env("PGAPPNAME", "supavisor_backup")
            .env("PGOPTIONS", "-c lock_timeout=15000")
            .env("LC_ALL", "C");
        if self.config.ssl_mode == "verify-full" {
            cmd.env("PGSSLROOTCERT", &self.config.ssl_root_cert);
        }
        let mut child = Guard(cmd.spawn()?);
        let (sender, receiver) = mpsc::sync_channel::<Vec<u8>>(8);
        let outputs: Vec<Box<dyn Read + Send>> = vec![
            Box::new(child.0.stdout.take().unwrap()),
            Box::new(child.0.stderr.take().unwrap()),
        ];
        for mut output in outputs {
            let sender = sender.clone();
            thread::spawn(move || {
                let mut data = [0u8; 4096];
                while let Ok(n) = output.read(&mut data) {
                    if n == 0 || sender.send(data[..n].to_vec()).is_err() {
                        break;
                    }
                }
            });
        }
        drop(sender);
        let mut tail = Vec::new();
        loop {
            self.check(false)?;
            match receiver.recv_timeout(Duration::from_millis(200)) {
                Ok(data) => {
                    tail.extend(data);
                    if tail.len() > 4096 {
                        tail.drain(..tail.len() - 4096);
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => (),
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    if let Some(status) = child.0.try_wait()? {
                        if status.success() {
                            return Ok(());
                        }
                        let message = String::from_utf8_lossy(&tail);
                        return Err(if self.config.password.is_empty() {
                            message.to_string()
                        } else {
                            message.replace(&self.config.password, "[redacted]")
                        }
                        .into());
                    }
                    thread::sleep(Duration::from_millis(100));
                }
            }
        }
    }
    fn verify(&mut self, path: &Path) -> Result<()> {
        let mut magic = [0u8; 5];
        File::open(path)?.read_exact(&mut magic)?;
        if &magic != b"PGDMP" {
            return Err("Use a custom-format pg_dump archive (.dump / .backup). Plain SQL is not supported.".into());
        }
        self.command(&[
            self.tool("pg_restore")?,
            "--list".into(),
            path.to_string_lossy().into_owned(),
        ])
    }
    fn dump(&mut self, path: &Path) -> Result<()> {
        let partial = self
            .config
            .directory
            .join(if path.file_name().unwrap() == "safety.dump" {
                "safety.partial"
            } else {
                "export.partial"
            });
        self.command(&[
            self.tool("pg_dump")?,
            "--no-password".into(),
            "--format=custom".into(),
            "--compress=6".into(),
            "--lock-wait-timeout=15000".into(),
            format!("--dbname={}", self.connection()),
            format!("--file={}", partial.display()),
        ])?;
        self.check(true)?;
        self.verify(&partial)?;
        fs::rename(partial, path)?;
        Ok(())
    }
    fn copy<R: Read, W: Write>(&mut self, mut input: R, mut output: W) -> Result<u64> {
        let mut buffer = vec![0u8; 1024 * 1024];
        let mut size = 0;
        loop {
            self.check(false)?;
            let count = input.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            size += count as u64;
            if size > self.config.max_bytes {
                return Err("Expanded backup exceeds the size limit.".into());
            }
            output.write_all(&buffer[..count])?;
        }
        Ok(size)
    }
    fn sha256(&mut self, path: &Path) -> Result<String> {
        let mut file = File::open(path)?;
        let mut digest = Sha256::new();
        let mut buffer = vec![0u8; 1024 * 1024];
        loop {
            self.check(false)?;
            let count = file.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            digest.update(&buffer[..count]);
        }
        Ok(format!("{:x}", digest.finalize()))
    }
    fn upload(&mut self) -> Result<PathBuf> {
        let upload = self.config.directory.join("upload");
        let target = self.config.directory.join("input.dump");
        let mut file = File::open(&upload)?;
        let mut magic = [0u8; 5];
        file.read_exact(&mut magic)?;
        if &magic == b"PGDMP" {
            fs::rename(&upload, &target)?;
        } else if magic.starts_with(b"PK") {
            zip_directory_limit(&mut file)?;
            file.seek(SeekFrom::Start(0))?;
            let mut archive = ZipArchive::new(file)?;
            if !(1..=2).contains(&archive.len()) {
                return Err("ZIP must contain one dump and optional manifest.json.".into());
            }
            let mut names = HashSet::new();
            let mut dump = None;
            for index in 0..archive.len() {
                let entry = archive.by_index(index)?;
                let name = entry.name();
                if !names.insert(name.to_string())
                    || entry.is_dir()
                    || entry.is_symlink()
                    || entry.encrypted()
                    || name.contains('\\')
                    || Path::new(name)
                        .components()
                        .any(|p| !matches!(p, Component::Normal(_)))
                {
                    return Err(
                        "ZIP contains an unsafe path, link, duplicate or encrypted entry.".into(),
                    );
                }
                if entry.size() > self.config.max_bytes {
                    return Err("Expanded ZIP content exceeds the size limit.".into());
                }
                let ext = Path::new(name)
                    .extension()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_lowercase();
                if ext == "dump" || ext == "backup" {
                    if dump.is_some() {
                        return Err("ZIP must contain exactly one PostgreSQL dump.".into());
                    }
                    dump = Some(index);
                } else if name != "manifest.json" || entry.size() > 65536 {
                    return Err("ZIP may contain only one dump and optional manifest.json.".into());
                }
            }
            let index = dump.ok_or("ZIP has no PostgreSQL dump")?;
            let entry = archive.by_index(index)?;
            let output = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&target)?;
            self.copy(entry, output)?;
            fs::remove_file(&upload)?;
        } else {
            return Err("Upload a PostgreSQL custom dump or ZIP containing one.".into());
        }
        self.verify(&target)?;
        Ok(target)
    }
    fn export(&mut self) -> Result<Value> {
        stage("Exporting database")?;
        let mut output = self.config.directory.join(if self.config.format == "dump" {
            "export.dump"
        } else {
            "export.tmp.dump"
        });
        self.dump(&output)?;
        if self.config.format == "zip" {
            stage("Packaging ZIP")?;
            let manifest = json!({"format": "pg_dump custom", "database": self.config.database, "server_version": self.config.server_version, "dump_sha256": self.sha256(&output)?});
            let partial = self.config.directory.join("export.partial");
            let mut zip = ZipWriter::new(File::create(&partial)?);
            let options = SimpleFileOptions::default()
                .compression_method(CompressionMethod::Stored)
                .unix_permissions(0o600);
            zip.start_file("manifest.json", options)?;
            zip.write_all(&serde_json::to_vec_pretty(&manifest)?)?;
            zip.start_file("database.dump", options.large_file(true))?;
            self.copy(File::open(&output)?, &mut zip)?;
            zip.finish()?;
            fs::remove_file(&output)?;
            output = self.config.directory.join("export.zip");
            fs::rename(partial, &output)?;
        }
        stage("Verifying backup")?;
        self.check(true)?;
        Ok(
            json!({"bytes": fs::metadata(&output)?.len(), "sha256": self.sha256(&output)?, "safety_bytes": 0}),
        )
    }
    fn restore(&mut self) -> Result<Value> {
        stage("Validating uploaded backup")?;
        let source = self.upload()?;
        self.check(true)?;
        stage("Creating safety backup")?;
        let safety = self.config.directory.join("safety.dump");
        self.dump(&safety)?;
        stage("Restoring database in one transaction")?;
        let mut args = vec![
            self.tool("pg_restore")?,
            "--no-password".into(),
            "--exit-on-error".into(),
            "--single-transaction".into(),
            "--no-tablespaces".into(),
            format!("--dbname={}", self.connection()),
        ];
        if self.config.mode.as_deref() == Some("replace") {
            args.extend(["--clean".into(), "--if-exists".into()]);
        }
        if self.config.ownership.as_deref() == Some("target") {
            args.extend([
                "--no-owner".into(),
                "--no-privileges".into(),
                format!("--role={}", self.config.owner),
            ]);
        }
        args.push(source.to_string_lossy().into_owned());
        self.command(&args)?;
        Ok(
            json!({"bytes": fs::metadata(source)?.len(), "safety_bytes": fs::metadata(safety)?.len()}),
        )
    }
}

struct Guard(Child);
impl Drop for Guard {
    fn drop(&mut self) {
        if matches!(self.0.try_wait(), Ok(Some(_))) {
            return;
        }
        unsafe {
            libc::kill(-(self.0.id() as i32), libc::SIGTERM);
        }
        for _ in 0..30 {
            if matches!(self.0.try_wait(), Ok(Some(_))) {
                return;
            }
            thread::sleep(Duration::from_millis(100));
        }
        unsafe {
            libc::kill(-(self.0.id() as i32), libc::SIGKILL);
        }
        let _ = self.0.wait();
    }
}
fn emit(value: Value) -> Result<()> {
    let mut out = io::stdout().lock();
    serde_json::to_writer(&mut out, &value)?;
    out.write_all(b"\n")?;
    out.flush()?;
    Ok(())
}
fn stage(name: &str) -> Result<()> {
    emit(json!({"event": "stage", "stage": name}))
}

// Bound central-directory allocations before constructing ZipArchive (ZIP64 too).
fn zip_directory_limit(file: &mut File) -> Result<()> {
    fn u16_at(b: &[u8], at: usize) -> u16 {
        u16::from_le_bytes(b[at..at + 2].try_into().unwrap())
    }
    fn u32_at(b: &[u8], at: usize) -> u32 {
        u32::from_le_bytes(b[at..at + 4].try_into().unwrap())
    }
    fn u64_at(b: &[u8], at: usize) -> u64 {
        u64::from_le_bytes(b[at..at + 8].try_into().unwrap())
    }
    let size = file.metadata()?.len();
    let start = size.saturating_sub(65557);
    file.seek(SeekFrom::Start(start))?;
    let mut data = Vec::new();
    file.read_to_end(&mut data)?;
    let index = data
        .windows(4)
        .rposition(|v| v == b"PK\x05\x06")
        .ok_or("Invalid ZIP archive")?;
    if data.len() < index + 22 {
        return Err("Invalid ZIP directory".into());
    }
    let record = &data[index..];
    if index + 22 + u16_at(record, 20) as usize != data.len()
        || u16_at(record, 4) != 0
        || u16_at(record, 6) != 0
    {
        return Err("Multipart or malformed ZIP archives are unsupported".into());
    }
    let mut count = u16_at(record, 10) as u64;
    let mut count_disk = u16_at(record, 8) as u64;
    let mut central_size = u32_at(record, 12) as u64;
    let mut central_offset = u32_at(record, 16) as u64;
    if count == 65535 || central_size == u32::MAX as u64 || central_offset == u32::MAX as u64 {
        let end = start + index as u64;
        if end < 20 {
            return Err("Invalid ZIP64 locator".into());
        }
        file.seek(SeekFrom::Start(end - 20))?;
        let mut locator = [0u8; 20];
        file.read_exact(&mut locator)?;
        if &locator[..4] != b"PK\x06\x07" || u32_at(&locator, 4) != 0 || u32_at(&locator, 16) != 1 {
            return Err("Invalid ZIP64 locator".into());
        }
        let location = u64_at(&locator, 8);
        if location >= end - 20 {
            return Err("Invalid ZIP64 offset".into());
        }
        file.seek(SeekFrom::Start(location))?;
        let mut directory = [0u8; 56];
        file.read_exact(&mut directory)?;
        if &directory[..4] != b"PK\x06\x06"
            || u32_at(&directory, 16) != 0
            || u32_at(&directory, 20) != 0
        {
            return Err("Invalid ZIP64 directory".into());
        }
        count_disk = u64_at(&directory, 24);
        count = u64_at(&directory, 32);
        central_size = u64_at(&directory, 40);
        central_offset = u64_at(&directory, 48);
    }
    if count != count_disk
        || !(1..=2).contains(&count)
        || central_size > 65536
        || central_offset
            .checked_add(central_size)
            .map_or(true, |v| v > size)
    {
        return Err("ZIP must contain one dump and optional manifest.json".into());
    }
    Ok(())
}
fn run() -> Result<()> {
    unsafe {
        libc::umask(0o077);
    }
    // Read exactly one line, without buffering later cancellation commands.
    let mut input = io::stdin();
    let mut bytes = Vec::new();
    for _ in 0..65536 {
        let mut b = [0u8; 1];
        input.read_exact(&mut b)?;
        if b[0] == b'\n' {
            break;
        }
        bytes.push(b[0]);
    }
    let config: Config = serde_json::from_slice(&bytes)?;
    let stopped = Arc::new(AtomicBool::new(false));
    let flag = stopped.clone();
    thread::spawn(move || {
        let _ = input.read(&mut [0u8; 1]);
        flag.store(true, Ordering::Relaxed);
    });
    let mut context = Context {
        deadline: Instant::now() + Duration::from_secs(config.timeout),
        last_check: Instant::now(),
        config,
        stopped,
    };
    let result = context.check(true).and_then(|_| {
        if context.config.operation == "export" {
            context.export()
        } else {
            context.restore()
        }
    });
    match result {
        Ok(mut data) => {
            data["event"] = json!("result");
            data["status"] = json!("completed");
            data["error"] = Value::Null;
            emit(data)?;
            Ok(())
        }
        Err(error) => {
            let status = if context.stopped.load(Ordering::Relaxed) {
                "cancelled"
            } else {
                "failed"
            };
            let message = error.to_string();
            let safe = if context.config.password.is_empty() {
                message
            } else {
                message.replace(&context.config.password, "[redacted]")
            };
            let _ = emit(
                json!({"event":"result", "status":status, "error":safe.chars().take(4500).collect::<String>(), "bytes":0, "safety_bytes":fs::metadata(context.config.directory.join("safety.dump")).map(|m|m.len()).unwrap_or(0)}),
            );
            Err("Backup operation failed".into())
        }
    }
}
fn main() {
    if run().is_err() {
        std::process::exit(1);
    }
}
