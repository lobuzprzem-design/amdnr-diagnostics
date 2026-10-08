# Validation of v1.0.0

Tested on 8 October 2026 with actual Windows PowerShell 5.1.26100.9549.

The final implementation passed 19 fixture test groups, including UTF-8/16/32 decoding, fallback encoding, bounded tail reads, enumeration/hash limits, duplicate source handling, junction exclusions, source immutability, secret masking, access-denied handling, simulated CIM/read/ZIP failures and a persistent report-write failure. The latter verifies that a failed final write does not leave a manifest claiming successful completion.

An independent command-line run on a separate synthetic game/log fixture passed 33 assertions: input file hashes remained unchanged; privacy canaries and excluded cache content were absent; the large-log tail and extra log source were retained; DLL metadata hashes were correct; and all ZIP entries matched their corresponding report files. Its expected status was partial because one log exceeded the input limit.

A separate real-machine system/HIP run found the HIP 7.2 runtime DLL, produced a readable ZIP and returned partial (exit 2) because the supplied historical game directory was missing.

Validated collector SHA256:

```text
749AB4710FACB4BD1A46DDBDBFDAB908D17A24AFE4A31B3E2D9FC712C5F004CB
```

No running-game integration test was performed. These checks do not establish mod/driver compatibility, successful NR execution, absence of all defects, or complete anonymization. The collector has no scheduling or upload functionality; any release monitoring or message publication is a separate workflow.
