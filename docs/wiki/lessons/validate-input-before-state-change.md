---
title: validate-input-before-state-change
status: current
source: tests/task_registry_test.go
---

# Validate input before state change

## What happened

The example specifies that blank task titles must be rejected without creating a task.

## How discovered

The regression test in `tests/task_registry_test.go` asserts both the error and unchanged list.

## Root cause

Mutating state before validating input would leave an invalid task behind.

## Fix

Trim and validate the title before assigning an ID or appending state.

## Future guardrail

Keep the rejection-and-no-state-change test. Related: [[task-registry]] and [[use-in-memory-storage-for-example]].

