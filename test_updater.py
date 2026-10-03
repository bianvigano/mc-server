"""Jalankan: python3 test_updater.py (tanpa jaringan/server Minecraft)."""
import io
from pathlib import Path
import tarfile
import tempfile
import updater


def archive(invalid=False):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w:gz") as bundle:
        for name in updater.FILES:
            content = b"#!/bin/bash\nexit 0\n" if name.endswith(".sh") else b"pass\n"
            if invalid and name == "start.sh":
                content = b"if\n"
            member = tarfile.TarInfo("release/" + name)
            member.size = len(content)
            bundle.addfile(member, io.BytesIO(content))
    return data.getvalue()


with tempfile.TemporaryDirectory() as directory:
    updater.ROOT = Path(directory)
    (updater.ROOT / "start.sh").write_text("lama\n")
    (updater.ROOT / "server.properties").write_text("server-port=25565\n")
    try:
        updater.install(archive(True), "v1")
        raise AssertionError("Skrip rusak seharusnya ditolak")
    except updater.subprocess.CalledProcessError:
        pass
    assert (updater.ROOT / "start.sh").read_text() == "lama\n"
    updater.install(archive(), "v1")
    assert (updater.ROOT / ".mc-tools-version").read_text() == "v1\n"
    assert (updater.ROOT / "server.properties").read_text() == "server-port=25565\n"
    backups = list((updater.ROOT / ".mc-update-backups").glob("*/start.sh"))
    assert len(backups) == 1 and backups[0].read_text() == "lama\n"
    assert (updater.ROOT / "start.sh").stat().st_mode & 0o111
print("[OK] Validasi arsip, pemasangan, cadangan, dan konfigurasi aman")
