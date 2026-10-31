export default {
  extends: ["@commitlint/config-conventional"],
  // Dependabot bodies contain long release-note lines we cannot control.
  ignores: [(message) => /^Bumps /m.test(message)],
};
