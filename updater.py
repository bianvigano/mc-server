#!/usr/bin/env python3
"""Perbarui skrip mc-server dari GitHub Releases, bukan JAR Minecraft."""
import argparse
import datetime
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent
REPO = "bianvigano/mc-server"
FILES = ("start.sh", "setup.sh", "backup.sh", "plugins.sh", "update.sh", "docker.sh", "updater.py")


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "mc-server-updater", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def install(archive, tag):
    # ponytail: hanya skrip dalam daftar tetap; tambahkan nama saat ada skrip baru.
    with tempfile.TemporaryDirectory(prefix=".mc-update-", dir=ROOT) as temporary:
        stage = Path(temporary)
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as bundle:
            members = {}
            for member in bundle.getmembers():
                parts = member.name.split("/")
                if len(parts) == 2 and parts[1] in FILES:
                    if not member.isfile() or parts[1] in members:
                        raise ValueError("Arsip rilis tidak valid")
                    members[parts[1]] = member
            if set(members) != set(FILES):
                raise ValueError("Rilis belum mendukung updater atau skrip tidak lengkap")
            for name, member in members.items():
                with bundle.extractfile(member) as source:
                    (stage / name).write_bytes(source.read())
                if name.endswith(".sh"):
                    subprocess.run(["bash", "-n", str(stage / name)], check=True)
                else:
                    compile((stage / name).read_bytes(), name, "exec")
        backup = ROOT / ".mc-update-backups" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        backup.mkdir(parents=True)
        existing = [name for name in FILES if (ROOT / name).exists()]
        for name in existing:
            if (ROOT / name).is_symlink() or not (ROOT / name).is_file():
                raise ValueError("Tujuan bukan file biasa: " + name)
            shutil.copy2(ROOT / name, backup / name)
        marker = ROOT / ".mc-tools-version"
        if marker.is_symlink():
            raise ValueError("Penanda versi tidak boleh symlink")
        old_marker = marker.read_bytes() if marker.exists() else None
        try:
            for name in FILES:
                (stage / name).chmod(0o755)
                (stage / name).replace(ROOT / name)
            marker.write_text(tag + "\n")
        except BaseException:
            for name in FILES:
                if name in existing:
                    shutil.copy2(backup / name, ROOT / name)
                else:
                    (ROOT / name).unlink(missing_ok=True)
            if old_marker is None:
                marker.unlink(missing_ok=True)
            else:
                marker.write_bytes(old_marker)
            raise
        print("[OK] Skrip diperbarui ke " + tag)
        print("Cadangan skrip lama: " + str(backup))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", nargs="?", default="cek", choices=("cek", "check", "pasang", "install"), help="cek rilis atau pasang pembaruan")
    args = parser.parse_args()
    try:
        release = json.loads(fetch("https://api.github.com/repos/" + REPO + "/releases/latest"))
        tag = release["tag_name"]
        if not isinstance(tag, str) or not tag or "\n" in tag:
            raise ValueError("Tag rilis tidak valid")
        marker = ROOT / ".mc-tools-version"
        current = marker.read_text().strip() if marker.exists() else "belum tercatat"
        print("Versi lokal: " + current)
        print("Rilis terbaru: " + tag)
        print("Halaman rilis: " + release["html_url"])
        if current == tag:
            print("[OK] Sudah versi terbaru")
            return 0
        if args.action in ("cek", "check"):
            print("Pasang: ./start.sh update pasang")
            return 0
        if (ROOT / ".git").exists():
            dirty = subprocess.check_output(["git", "status", "--porcelain", "--", *FILES], cwd=ROOT, text=True)
            if dirty:
                raise ValueError("Ada perubahan lokal pada skrip. Simpan perubahan sebelum memperbarui")
        install(fetch("https://api.github.com/repos/" + REPO + "/tarball/" + urllib.parse.quote(tag, safe="")), tag)
        return 0
    except urllib.error.HTTPError as error:
        if error.code == 404:
            print("[ERR] Belum ada GitHub Release stabil yang tersedia", file=sys.stderr)
        else:
            print("[ERR] GitHub HTTP " + str(error.code), file=sys.stderr)
    except (OSError, ValueError, KeyError, tarfile.TarError, subprocess.SubprocessError, SyntaxError) as error:
        print("[ERR] Pembaruan gagal: " + str(error), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
