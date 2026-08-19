---
type: "agent_requested"
description: "Example description"
---

When doing Powershell modules, apply the following
*no async/await
*No updating progress bars from background threads because it does not work
*No workarounds and simpler approaches without asking first
*Code according to best practices
*Code quality is that goal, not quick delivery
*Think about what is needed before implementation so we can have reusable code across the code base, so BaseCmdlets, inherits, Classes, Models, Methods
*Add write progress to cmdlets where approriate
*The Module folder should not be gitignored
*Build artifcacts should go into the Artifacts folder
*All docs except the Readme should go into the docs folder
*Any scripts should go into the scripts folder
*A changelog should be kept
*Constant printing of excessive information to the threads should not occur to keep the project concise
*New threads speed up performance but should not forget the progress of the previous thread so we can pick up where we left off
*Release format is yyyy.mm.dd.hhmm in all cases
*Folder structure should be like below
├── Artifacts/
├── docs/
├── Module/
│   └── PSDeviceEnrollmentTools/
│       ├── lib/
│       └── types/
├── Releases/
│   └── yyyy.MM.dd.HHmm/
├── src/
│   ├── Cmdlets/
│   ├── Models/
│   └── Utils/

 
├── Artifacts/
├── docs/
├── Module/
│   └── PSDeviceEnrollmentTools/
│       ├── lib/
│       └── types/
├── Releases/
│   └── yyyy.MM.dd.HHmm/
├── src/
│   ├── Cmdlets/
│   ├── Models/
│   └── Utils/