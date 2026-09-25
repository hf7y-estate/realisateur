#!/usr/bin/env bash
# estate-set.sh -- the estate's own names, one home (hf7y/realisateur#673, #672).
GH_ESTATE_OWNER="${GH_ESTATE_OWNER:-hf7y-estate}"
GH_ESTATE_SITE="${GH_ESTATE_SITE:-hf7y.com}"
GH_ESTATE_SITE_REPO="${GH_ESTATE_SITE_REPO:-hf7y.github.io}"
# THE PAGES REPO HAS ITS OWN OWNER, PERMANENTLY. Zach, 2026-09-24, asked what
# to do with hf7y.github.io during the org cutover: "2 park forever". So this is
# a decision, not a migration leftover to tidy up later.
#
# `hf7y.github.io` is a USER Pages repo serving hf7y.com from a CNAME in its
# tree. A transfer can drop the Pages domain config and hf7y.com is a live
# address, so it stayed under `hf7y` while the other 54 moved to the org.
# Composing $GH_ESTATE_OWNER/$GH_ESTATE_SITE_REPO would address
# `hf7y-estate/hf7y.github.io`, which does not exist -- the silent-miss class
# #673 gave these names one home to prevent, caught BY that home.
GH_ESTATE_SITE_OWNER="${GH_ESTATE_SITE_OWNER:-hf7y}"
# THE HUMAN IS NOT THE NAMESPACE. Before the cutover both were `hf7y`, so one
# name served two jobs and nothing noticed. `answered.jq:38` matches
# `.author.login == $owner` -- Zach's GitHub login -- and flipping the namespace
# to the org made it match nobody, so every DECISION he had already answered
# would have kept its `needs-human` label and gone on braking dispatch. Caught
# by bin/tests/etiquette.test.sh, which went 63/0 to 57/6 on the flip alone.
GH_ESTATE_HUMAN="${GH_ESTATE_HUMAN:-hf7y}"
# WHERE THE ARMING AUTHORITY ANSWERS (hf7y/scheduler#429). 100.107.253.56 is
# dexter's tailnet address AND monkey's own eth0 -- one WSL2 namespace, so one
# default reaches mandark and monkey both (measured 2026-09-01).
GH_ESTATE_ROSTER_URL="${GH_ESTATE_ROSTER_URL:-http://100.107.253.56:8646}"
