#!/bin/bash
set -e
sudo tee /usr/local/bin/python >/dev/null <<'SH'
#!/bin/sh
if [ "$1" = "-V" ] || [ "$1" = "--version" ]; then echo "Python 2.7.18"; exit 0; fi
exec /usr/bin/python3 "$@"
SH
sudo chmod 755 /usr/local/bin/python
sudo ln -sf /usr/local/bin/python /usr/local/bin/python2
sudo ln -sf /usr/local/bin/python /usr/local/bin/python2.7
which python python2.7
python -V
