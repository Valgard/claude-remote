/* claude-remote anchor app stub.
 * The CFBundleExecutable of ClaudeRemoteAnchor.app. Its only job is to become the
 * LaunchServices-tracked, grantable responsible process, then hand off to the shell
 * supervisor via exec (same PID, so the app identity is retained). CRP_PATH is baked
 * in at build time by install.sh (-DCRP_PATH="<abs path to claude-remote-pick>").
 */
#include <stdio.h>
#include <unistd.h>

int main(void) {
  execl(CRP_PATH, "claude-remote-pick", "--supervise-anchor", (char *)0);
  perror(CRP_PATH);
  return 127; /* exec failed */
}
