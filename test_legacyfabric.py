#!/usr/bin/env python3
"""Offline stdlib checks for LegacyFabric setup/launcher integration."""
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent
setup = (repo / 'setup.sh').read_text()
function = setup.split('download_legacyfabric() {', 1)[1].split('\ndownload_fabric()', 1)[0]
flags = (repo / 'start.sh').read_text().split('set_java_flags_by_type() {', 1)[1].split('\n}\n', 1)[0]
scratch = Path(os.environ.get('TMPDIR', Path.home() / '.hermes/cache/scratch'))
scratch.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(dir=scratch) as tmp:
    def run(script):
        return subprocess.run(['bash', '-c', script], cwd=tmp, text=True, capture_output=True)
    # Exercise actual function bodies; curl fixtures are intentional offline inputs.
    fixture = '''
curl() {
case "${@: -1}" in
*/game) printf '%s' '[{"version":"1.8.9","stable":true}]' ;;
*/loader/1.8.9) printf '%s' '[{"loader":{"version":"0.20.1","stable":true},"launcherMeta":{"min_java_version":8}}]' ;;
*/installer) printf '%s' '[{"version":"1.1.1","stable":true,"url":"https://maven.legacyfabric.net/installer.jar"}]' ;;
*) return 0 ;;
esac
}
java() { printf 'offline launcher fixture' > "$INSTALL_DIR/fabric-server-launch.jar"; }
MC_VERSION=1.8.9 LEGACYFABRIC_LOADER= LEGACYFABRIC_INSTALLER= JAVA_VER=21 INSTALL_DIR="$PWD"
'''
    body = 'set -e\ndownload_legacyfabric() {' + function + '\n'
    result = run(body + fixture + '\ndownload_legacyfabric\n[[ "$SERVER_JAR" == fabric-server-launch.jar && "$LEGACYFABRIC_LOADER" == 0.20.1 ]]')
    assert result.returncode == 0, result.stderr + result.stdout
    for variable, value in [('MC_VERSION', '1.21.4'), ('LEGACYFABRIC_LOADER', 'invalid'), ('LEGACYFABRIC_INSTALLER', 'invalid'), ('JAVA_VER', '7')]:
        result = run(body + fixture + f'\n{variable}={value}\ndownload_legacyfabric')
        assert result.returncode != 0, (variable, result.stdout)
    result = run('set_java_flags_by_type() {' + flags + '\n}\nSERVER_TYPE=legacyfabric\nDEFAULT_JAVA_FLAGS="-XX:+UseG1GC"\nset_java_flags_by_type\n[[ "$JAVA_FLAGS" != *MaxMetaspaceSize* ]]')
    assert result.returncode == 0, result.stderr
result = subprocess.run(['bash', str(repo / 'setup.sh'), '--legacyfabric-loader'], capture_output=True, text=True)
assert result.returncode != 0 and 'requires a version' in result.stdout
print('LegacyFabric: install selection, invalid versions, Java minimum, flags, missing argument: OK')
