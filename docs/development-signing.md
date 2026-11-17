# Automatic login in development builds

**English** | [한국어](development-signing.ko.md)

Repeated Keychain prompts after rebuilding the UI were caused by ad hoc signing and macOS Keychain partition checks. Even when a self-signed certificate fixes the designated requirement, programs without an Apple team identifier may be subject to a build-specific `cdhash` partition. Actual checks also denied Keychain sharing between two programs with different binary contents.

The current build handles this as follows.

- The app and helper are signed with the same local development certificate stored in the login Keychain. Root certificate trust and TLS trust settings are unchanged.
- `Contents/Helpers/SynologyCredentialHelper` handles Keychain access. This binary is updated only when the helper or CredentialStore sources change, and is reused unchanged for UI edits.
- The app checks the helper's signature before launching it. The helper also verifies that its parent process is `com.damho.SynologyMarkdown` signed with the same certificate. Requests from arbitrary terminal programs or other apps are rejected before accessing the Keychain.
- Passwords and NAS device tokens pass only through the processes' standard input/output pipes; they are not stored in command arguments, files, or logs. The helper process is terminated if an automatic read does not finish within 3 seconds, or a user-requested Keychain confirmation does not finish within 180 seconds.

When switching from the existing app to the helper, macOS requires one access confirmation for the existing NAS Keychain item. Select “Always Allow.” Subsequent UI rebuilds and app relaunches connect automatically using the saved password and device token. Further confirmation may be required if the helper itself changes, the NAS revokes device trust, or the Keychain is locked.

The development certificate's public fingerprint is saved in `~/Library/Application Support/SynologyMarkdown/DevelopmentSigning/identity.json`, while its private key is kept only in the login Keychain. Do not arbitrarily replace this file or certificate.

## Verification

```sh
rtk proxy python3 script/test_signing.py
rtk proxy ./script/test.sh
rtk proxy ./script/build_and_run.sh
```

The signing check verifies that two different app binaries can save and read a synthetic account's password and device token through the same helper. It also checks that requests from an unrelated parent process and from an app signed with a different identifier are rejected. No actual NAS account is used in this check.

References: [Apple code signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), [macOS code signing and Keychain](https://developer.apple.com/library/archive/technotes/tn2206/).
