// bun:test has no in-test skip, so a live test that cannot run says so and returns.
// Printed rather than silent: a green run that quietly tested nothing is worse than a
// red one, and these only ever run when someone asked for them.
export function skipped (why) {
  console.log(`  skipped: ${why}`)
}
