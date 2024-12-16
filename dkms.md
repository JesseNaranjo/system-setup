## dkms install

Most default installs will not include dkms
- Instal `dkms` package
- Create mok.key and mok.pub in `/var/lib/dkms`:
  - `openssl req -newkey rsa:4096 -nodes -keyout mok.key -new -x509 -sha256 -subj "/CN=DKMS Signing Key" -outform DER -out mok.pub`
- Add key to the trusted list:
  - `mokutil --import /var/lib/dkms/mok.pub`
- Restart, follow shim steps
  1. Enroll MOK
  2. Continue
  3. Enter Password (from the `mokutil --import` command)
  4. Reboot
