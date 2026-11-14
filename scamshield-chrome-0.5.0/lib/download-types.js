// Which downloads count as "risky" (held for approval under hold_risky),
// and safe ways to show a file name to the admin.
//
// Risky = anything that can run code, carry a macro, or open as a web page,
// plus files whose type cannot be told. Plain documents, pictures, audio and
// video are not risky.

const RISKY_EXTENSIONS = new Set([
  // programs and installers
  "exe", "msi", "msix", "appx", "msp", "com", "scr", "dll", "sys", "pif", "gadget", "bin", "run",
  "app", "dmg", "pkg", "deb", "rpm", "appimage", "apk", "jar", "iso", "img",
  // scripts and shortcuts
  "bat", "cmd", "ps1", "vbs", "vbe", "js", "jse", "wsf", "wsh", "hta", "reg", "lnk", "url",
  "sh", "bash", "py", "pl", "rb",
  // Linux launchers and installers
  "desktop", "xpi", "flatpakref", "flatpak", "jnlp", "snap",
  // archives (can hide any of the above)
  "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "cab", "z",
  // Office files that can carry macros, including old formats
  "doc", "xls", "ppt", "docm", "xlsm", "pptm", "dotm", "xltm", "xla", "ppam", "xlam",
  // things that open like a web page
  "html", "htm", "xhtml", "shtml", "svg", "mht", "mhtml",
]);

const RISKY_MIME_TYPES = new Set([
  "application/x-msdownload", "application/x-dosexec", "application/x-executable",
  "application/x-sh", "application/x-shellscript", "application/java-archive",
  "application/vnd.android.package-archive", "application/x-msi", "application/x-apple-diskimage",
  "application/hta", "text/html", "application/xhtml+xml", "image/svg+xml",
  // archives and legacy Office files, by type (Chrome often has no file name yet)
  "application/zip", "application/x-zip-compressed", "application/x-rar-compressed", "application/vnd.rar",
  "application/x-7z-compressed", "application/x-tar", "application/gzip", "application/x-gzip",
  "application/x-bzip2", "application/x-xz", "application/x-iso9660-image",
  "application/msword", "application/vnd.ms-excel", "application/vnd.ms-powerpoint",
  "application/vnd.ms-word.document.macroenabled.12", "application/vnd.ms-excel.sheet.macroenabled.12",
  "application/vnd.ms-powerpoint.presentation.macroenabled.12",
]);

const UNKNOWN_MIME_TYPES = new Set(["", "application/octet-stream", "binary/octet-stream", "application/force-download"]);

// Last file extension, lowercase, ignoring trailing dots and spaces
// ("invoice.pdf.exe" -> "exe", "a.exe. " -> "exe", "README" -> "").
export function fileExtension(name) {
  const base = lastSegment(name).replace(/[. ]+$/, "");
  const dot = base.lastIndexOf(".");
  return dot > 0 || (dot === 0 && base.length > 1) ? base.slice(dot + 1).toLowerCase() : "";
}

// Last path segment, cleaned of control and direction-changing characters but
// NOT shortened. Decisions (the extension) and saved names use this.
export function lastSegment(path) {
  const name = String(path ?? "").split(/[\\/]/).pop() ?? "";
  // eslint-disable-next-line no-control-regex
  return name.replace(/[\u0000-\u001f\u007f‪-‮⁦-⁩]/g, "").trim();
}

// File name without folders, for showing to people: at most 80 characters.
export function basename(path) {
  const clean = lastSegment(path);
  return clean.length > 80 ? `${clean.slice(0, 77)}...` : clean;
}

// A readable file name taken from a web address: no query string or fragment.
export function nameFromUrl(url) {
  try {
    return lastSegment(decodeURIComponent(new URL(url).pathname));
  } catch {
    return "";
  }
}

// Returns { risky, reason }. Decides by the real (last) extension and the type
// the server claims; either one being risky is enough.
export function isRiskyDownload({ filename, mime }) {
  const extension = fileExtension(filename);
  const type = String(mime ?? "").split(";")[0].trim().toLowerCase();

  if (RISKY_EXTENSIONS.has(extension)) return { risky: true, reason: `extension_${extension}` };
  if (RISKY_MIME_TYPES.has(type)) return { risky: true, reason: `type_${type}` };
  if (extension === "" && UNKNOWN_MIME_TYPES.has(type)) return { risky: true, reason: "unknown_type" };
  if (UNKNOWN_MIME_TYPES.has(type) && !KNOWN_SAFE_EXTENSIONS.has(extension)) {
    return { risky: true, reason: "unknown_type" };
  }
  return { risky: false, reason: "ordinary_file" };
}

// Extensions that are fine even when the server calls them octet-stream.
const KNOWN_SAFE_EXTENSIONS = new Set([
  "pdf", "txt", "rtf", "csv", "docx", "xlsx", "pptx", "odt", "ods", "odp",
  "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic",
  "mp3", "wav", "flac", "ogg", "m4a", "mp4", "mov", "mkv", "avi", "webm",
]);
