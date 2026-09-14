# Engineering rules

- Make the smallest complete change; prefer established patterns over abstractions.
- Do not speculate, upgrade dependencies, or change public contracts unless the task requires it.
- Validate inputs at boundaries and return clear errors without leaking sensitive data.
- Behavior changes require tests; bugs receive regression tests when practical.
- Never weaken a test merely to pass implementation.
- Keep functions focused and handle expected failure paths explicitly.

