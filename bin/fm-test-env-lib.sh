#!/usr/bin/env bash
# bin/fm-test-env-lib.sh - the fleet-home overrides a firstmate test must never
# inherit from whoever invoked it.
#
# A test builds its own home and passes the overrides it wants per command. An
# ambient one - and every firstmate-spawned shell exports FM_HOME - is a second,
# invisible input that can silently decide a verdict: bin/fm-guard.sh and
# bin/fm-supervision-instructions.sh resolve CONFIG from FM_HOME BEFORE they fall
# back to FM_ROOT_OVERRIDE, so a fixture that sets only FM_ROOT_OVERRIDE has its
# config probes answered by a real home, and bin/fm-arm-pretool-check.sh reads
# FM_HOME as a classification input outright. That is how a case can be red in an
# operator's shell and green on a bare CI runner, in either direction.
#
# Single owner of the list. bin/fm-test-run.sh scrubs it around every script it
# schedules (including the ~50 that source no test library), and tests/lib.sh
# scrubs it at source time so a direct `bash tests/<x>.test.sh` run gets the
# identical environment the lane does.
#
# shellcheck shell=bash

# Consumed by the sourcing scripts, not by this list-only library.
# shellcheck disable=SC2034
FM_TEST_INHERITED_OVERRIDES=(
  FM_HOME
  FM_STATE_OVERRIDE
  FM_DATA_OVERRIDE
  FM_ROOT_OVERRIDE
  FM_PROJECTS_OVERRIDE
  FM_CONFIG_OVERRIDE
  FM_BACKEND
)
