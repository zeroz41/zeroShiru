/// Small logging seam shared by long-running application workflows.
///
/// Messages must never contain credentials, magnets, or signed stream URLs.
abstract interface class AppLog {
  void log(String level, String scope, String message);
}

class NoopAppLog implements AppLog {
  const NoopAppLog();

  @override
  void log(String level, String scope, String message) {}
}
