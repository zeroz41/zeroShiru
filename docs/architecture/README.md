# Architecture report artifacts

- `flutter-rewrite-architecture.md` is the editable source of truth.

Render a shareable copy from the repository root:

```bash
pandoc docs/architecture/flutter-rewrite-architecture.md --standalone --toc --number-sections --css report.css --metadata pagetitle='zeroShiru Flutter Rewrite' -o docs/architecture/flutter-rewrite-architecture.html
chromium --headless --no-sandbox --disable-gpu --allow-file-access-from-files --no-pdf-header-footer --print-to-pdf="$PWD/docs/architecture/flutter-rewrite-architecture.pdf" "file://$PWD/docs/architecture/flutter-rewrite-architecture.html"
```

Rendered HTML/PDF are build artifacts; don't commit them.
