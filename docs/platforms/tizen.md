# Tizen TV target

Zero's future Samsung TV runner belongs in `tizen/` at the repository root.
`tizenos/` is not the directory used by Flutter-Tizen.

Do not add a placeholder runner. Generate it from the application root with the
official Flutter-Tizen SDK when the target is actively implemented:

```bash
flutter-tizen create .
flutter-tizen build tpk --device-profile tv
```

The generated project includes `tizen/tizen-manifest.xml`; release builds are
written below `build/tizen/tpk/`. Keep generated build output ignored just like
the other Flutter targets.

## Readiness gates

- Replace the desktop/mobile libmpv implementation behind `MediaEngine` with a
  Tizen AVPlay/video-hole adapter.
- Audit every Flutter plugin in `pubspec.yaml` for Tizen support and provide an
  adapter or deliberate fallback where one is unavailable.
- Add remote-control focus, back-button, lifecycle, resume, subtitle, and
  protected-stream tests on a physical Samsung TV.
- Configure a unique Samsung package ID, certificates, privileges, TV profile,
  icons, and store metadata in `tizen/tizen-manifest.xml`.
- Add the TPK build to CI only after a pinned Flutter-Tizen SDK can reproduce it.

Baseline support is Tizen 6.0 / Samsung 2021 TVs and newer. Older TV generations
remain outside the supported matrix.

## Upstream references

- [Flutter-Tizen](https://github.com/flutter-tizen/flutter-tizen)
- [Getting started](https://github.com/flutter-tizen/flutter-tizen/blob/master/doc/get-started.md)
- [Publishing a Tizen application](https://github.com/flutter-tizen/flutter-tizen/blob/master/doc/publish-app.md)
