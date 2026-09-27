# The whole agent image. This belongs in the repo it serves, beside its
# workflow -- one folder, the repo's own utilities. node:22 is already on
# dexter's disk, so this is a thin delta layer, not a new 1.6 GB pull.
FROM node:22

RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh jq \
 && rm -rf /var/lib/apt/lists/*

# NAME THE NATIVE PACKAGE. `npm install -g @anthropic-ai/claude-code` alone
# pulls it as an OPTIONAL dependency, and when that download fails npm says
# nothing, the postinstall reports the miss AT rc=0, and the installed `claude`
# prints "native binary not installed" -- also at exit 0 under some shells. A
# whole unattended pass ran to completion on that: cloned, "ran", exit 0, did
# nothing. Measured 2026-09-24, npm config clean (omit empty, ignore-scripts
# false), so this is a download failure that reports as a healthy install.
#
# `claude --version` on its own line is the assertion. It makes a missing
# binary a FAILED BUILD here, instead of a silent empty run every night.
RUN npm install -g @anthropic-ai/claude-code @anthropic-ai/claude-code-linux-x64 \
 && claude --version

WORKDIR /work
