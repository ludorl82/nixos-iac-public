# The kp-get package, factored out so jumphost-tools.nix (systemPackages)
# and jumphost.nix (wan-ip-sync's PATH) can share one definition — both
# importing this file evaluate to the same derivation/store path.
#
# Same contract as console-vm's original /usr/local/bin/kp-get
# (net-cfgs/credentials.md): fetch the live .kdbx from cloud-01 each call,
# print ONLY the password field. Read-only and idempotent — safe to serve
# from more than one host at once (jumphost + console).
{ pkgs }:
let
  kpPython = pkgs.python3.withPackages (ps: [ ps.pykeepass ]);
in
pkgs.writeScriptBin "kp-get" ''
  #!${kpPython}/bin/python3
  import os, subprocess, sys, tempfile
  from pykeepass import PyKeePass

  KDBX_REMOTE_HOST = "cloud-01"
  KDBX_REMOTE_PATH = "/opt/keepass/ludovic.kdbx"
  KEYFILE_PATH = os.path.expanduser("~/OneDrive/Documents/Certificats/ludovic-2.key")
  PASSWORD_FILE = os.path.expanduser("~/.keepass_password")

  def fetch_kdbx(local_path):
      result = subprocess.run(
          ["${pkgs.openssh}/bin/ssh", "-o", "ConnectTimeout=5", KDBX_REMOTE_HOST,
           "sudo cat " + KDBX_REMOTE_PATH],
          capture_output=True, check=True)
      with open(local_path, "wb") as f:
          f.write(result.stdout)

  def main():
      if len(sys.argv) != 2:
          print('usage: kp-get "Entry Title"', file=sys.stderr)
          sys.exit(1)
      title = sys.argv[1]
      with open(PASSWORD_FILE) as f:
          db_password = f.read().strip()
      with tempfile.NamedTemporaryFile(suffix=".kdbx") as tmp:
          fetch_kdbx(tmp.name)
          kp = PyKeePass(tmp.name, password=db_password, keyfile=KEYFILE_PATH)
          entry = kp.find_entries(title=title, first=True)
          if entry is None:
              print("kp-get: no entry titled '%s'" % title, file=sys.stderr)
              sys.exit(1)
          sys.stdout.write(entry.password)

  main()
''
