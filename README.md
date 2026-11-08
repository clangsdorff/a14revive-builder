# a14revive builder for Samsung Galaxy A14 4G

GitHub Actions workflow that builds a TWRP installable One UI port from a patchset repo.

**Features**

- Downloads the latest donor and target firmware with samloader-rs
- Patches and signs framework and app files from the patchset
- Rebuilds system, product and vendor
- Adds a langsdorffkernel release
- Packs a TWRP zip and uploads it to gofile

# Setup

Add these repository secrets:

| Secret | Required | Content |
|---|---|---|
| `SIGN_KEY_PK8` | Yes | Platform key in PK8 format, base64 encoded |
| `SIGN_CERT_PEM` | Yes | Platform certificate in PEM format |
| `GOFILE_TOKEN` | No | gofile account token |

# Usage

Open Actions, select `Build`, then run the workflow with these inputs:

| Input | Description |
|---|---|
| `mode` | `port` (donor system on target vendor) or `stock` (one firmware, deodexed) |
| `source_fw` | Donor firmware version (`PDA/CSC/MODEM/BOOTLOADER`), empty for latest |
| `target_fw` | Target firmware version, empty for latest. Not used in `stock` |
| `patch_repo` | Patchset repo (`owner/name`) |
| `patch_ref` | Patchset branch or tag |
| `source_model` | Donor model |
| `source_csc` | Donor CSC |
| `target_model` | Target model |
| `target_csc` | Target CSC |
| `rom_version` | ROM version |
| `kernel_tag` | langsdorffkernel release tag |
| `kernel_variant` | Kernel variant (`e`, `en`, `p`, `pn`) |

The gofile link is written to the job summary. The file name is `a14revive@<rom_version>_<donor build>.zip`.

# Patchset layout

`stock` mode needs `apply_patches.sh`, `apktool.jar`, `patches/<name>_out.patch`, `port/debloat.txt`, `port/vendor_debloat.txt`, `port/system.prop`, `port/vendor.prop`, `port/sff.txt`, `port/files/{system,product,vendor}/` and `tools/updater-script`.

`port` mode needs:

```
apply_patches.sh
apktool.jar                 optional, 3.0.2 is downloaded if missing
patches/<name>_out.patch
port/bt_apex.py
port/debloat.sh
port/files/{system,product}/   optional
port/floating_feature.py
port/from_target.py
port/from_target.txt
port/install_apks.py
port/props.py
port/public_libs.txt
port/sepolicy.py
port/sff.txt
port/system.prop
tools/avb/avbtool.py
tools/avb/testkey_rsa4096.pem
tools/updater-script
```

`<name>` must match a jar or apk in the donor system or product image.

**Known Issues**

- Patchsets must use the layout above.

**Join / Follow**

- Telegram: https://t.me/a14stuffs

**Credits**

- @topjohnwu for samloader-rs
- @iBotPeaches for Apktool
- @salvogiangri for UN1CA
