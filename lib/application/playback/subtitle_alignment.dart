/// Estimates the constant timing offset between two subtitle tracks from the
/// cue start times observed during playback.
///
/// Independently authored tracks (a broadcast Japanese file against an
/// embedded English track, say) usually disagree by one constant shift, which
/// is exactly what mpv's per-track delay corrects. Watching a few lines gives
/// enough evidence to measure that shift: pair each primary cue start with
/// the nearest secondary start, discard pairs too far apart to be the same
/// line, and take the median — robust against the occasional sign line or
/// split cue that has no true partner.
library;

/// Below this a track pair is effectively in sync and an adjustment would
/// only churn the persisted tuning.
const Duration alignmentDeadband = Duration(milliseconds: 80);

/// Pairs further apart than this are assumed to be unrelated lines.
const Duration alignmentSearchWindow = Duration(seconds: 6);

/// Fewer observed pairs than this is not evidence, it is coincidence.
const int alignmentMinimumSamples = 5;

/// The adjustment to ADD to the secondary track's current delay so its cues
/// land on the primary track's timing, or null when the observed cues do not
/// support a confident estimate. Inputs are display-adjusted start times
/// (raw cue start plus that track's current delay), in any order.
Duration? suggestedSecondaryDelayAdjustment({
  required List<Duration> primaryStarts,
  required List<Duration> secondaryStarts,
}) {
  if (primaryStarts.length < alignmentMinimumSamples ||
      secondaryStarts.length < alignmentMinimumSamples) {
    return null;
  }
  final primary = [...primaryStarts]..sort();
  final secondary = [...secondaryStarts]..sort();

  final deltas = <int>[];
  var cursor = 0;
  for (final start in primary) {
    while (cursor + 1 < secondary.length &&
        (secondary[cursor + 1] - start).abs() <=
            (secondary[cursor] - start).abs()) {
      cursor++;
    }
    final delta = secondary[cursor] - start;
    if (delta.abs() <= alignmentSearchWindow) deltas.add(delta.inMilliseconds);
  }
  if (deltas.length < alignmentMinimumSamples) return null;

  deltas.sort();
  final middle = deltas.length ~/ 2;
  final median = deltas.length.isOdd
      ? deltas[middle]
      : (deltas[middle - 1] + deltas[middle]) ~/ 2;
  final correction = Duration(milliseconds: -median);
  if (correction.abs() <= alignmentDeadband) return Duration.zero;
  return correction;
}
