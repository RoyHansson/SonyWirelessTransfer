# Third-Party Notices

## Main App

The main Sony Wireless Transfer macOS app is built with Apple system frameworks only:

- `SwiftUI`
- `AppKit`
- `Foundation`
- `Darwin`
- `ServiceManagement`

It does not use third-party Swift packages or external UI/tooling libraries.

## Optional USB Pairing Helper

The optional USB pairing helper is `sony-guid-setter.c`.

That file is not fully original project code. Its file header states that it is heavily derived from:

- `xusb.c`
  Copyright 2009-2012 Pete Batard
- Sony GUID setting protocol reverse engineering
  Copyright 2016 Clemens Fruhwirth

The header in `sony-guid-setter.c` states that this helper is distributed under the GNU Lesser General Public License, version 2.1 or later.

The helper also links against `libusb 1.0`.

For release packaging, this repository now builds that helper from source and bundles the required `libusb` dynamic library alongside the helper instead of shipping an opaque prebuilt helper binary from the repository root.

The LGPL license text used for this helper and `libusb` is included in:

- [LICENSES/LGPL-2.1-or-later.txt](LICENSES/LGPL-2.1-or-later.txt)

If you want a release with no third-party-derived USB component at all, the safest option is to remove the USB pairing feature from the app entirely.
