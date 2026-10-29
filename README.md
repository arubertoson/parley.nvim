# parley.nvim

> Let's talk about this change.

`parley.nvim` keeps conversations beside ordinary workspace source buffers, not
in a permanent chat panel. Compose notes locally and submit them explicitly.
Your Neovim configuration owns the layout and statusline.

There are two separate workflows:

- **Review:** `/review` offers a context-free, read-only review. One isolated
  reviewer session handles explicit editor requests; the parent Pi conversation
  remains available. The reviewer has restricted discovery/publication tools,
  not source-editing authority. Tool restrictions are not an OS sandbox.
- **Standalone Parley:** `/parley` branches the parent context into an independent
  normal Pi child for implementation. The parent waits while editor turns drive
  the child. It can edit the shared workspace using its normal tools; this is not
  an isolated checkout or a filesystem fork.

## Status and requirements

Personal software, still under development; no release or compatibility promise.
Automated/offline checks exercise Neovim 0.13-dev and installed Pi 1.3.0. Integrated
human/live-model validation remains pending; scripted checks are not UX approval.

- Neovim with the experimental `nvim__ns_set` API and Unix-domain socket support.
- An interactive Pi process with a persistent transcript and selected model.
- A Git or jj workspace. The recorded starting commit is not a complete snapshot
  of dirty source buffers or the working tree.

## Installation

Install the two parts separately from the same local checkout.

### 1. Neovim

Register the checkout in your Neovim configuration/plugin manager, or add it to
`runtimepath` during startup:

```lua
vim.opt.runtimepath:prepend("/absolute/path/to/parley.nvim")
```

No `setup()` call is required. `:checkhealth parley` reports host capabilities and
cached pairing state without starting review work.

### 2. Pi

```sh
pi install /absolute/path/to/parley.nvim
```

Alternatively, add that path to `packages` in `~/.pi/agent/settings.json`.
Run `/reload` or restart Pi afterward. When migrating, remove the old `review.ts`
extension so only Parley registers `/review`. Neither part installs the other.
Reloading does not restore a prior review owner.

## Review workflow

1. **Offer a review in Pi:** run `/review` without arguments from the idle parent
   session. It records a baseline and publishes the workspace offer; it does not
   start the reviewer or inherit the parent's conversation, decisions or skills.
   The model/thinking selection is frozen for this review; there is no fallback.
2. **Optionally prepare it:** explicitly ask the parent to prepare a review
   handoff using `parley_prepare`, with an objective, scope, decisions, guidelines
   and curated context with source provenance. Preparation is bounded and starts
   no reviewer work. It is optional, not a prerequisite for pairing or requests.
3. **Pair in Neovim:** from an ordinary source window in the same workspace, in
   Normal mode, run `:ReviewStart`. Pairing, health checks and reconnect do not
   capture comments or start model work.
4. **Submit explicitly:** choose one of the following, after initialization and
   any preceding request have settled. Busy work is rejected, not queued.

   | Command | What is submitted |
   | --- | --- |
   | `:ReviewInvestigate <instructions>` | Free-form investigation instructions; no comment drafts |
   | `:ReviewAsk` | Eligible new/revised human prose across workspace conversations, not just the selected note |

   The reviewer can publish new source-anchored findings and exact-history
   replies. Discovery reads disk, not unsaved editor buffers; submitted editor
   captures retain their own original source provenance.
5. **Read and follow up:** compatible publications enter local history without
   opening files or stealing focus. Navigate notes and submit further prose with
   `:ReviewAsk`, or request another investigation. Captured text that cannot be
   safely placed stays unplaced rather than being matched to a guessed location.
   Valid placement in a loaded buffer is not a current-disk claim.
6. **Choose how to work:** collect findings first and fix later, or edit source
   yourself between requests and investigate again. Review never applies fixes.
   Editing code does not refresh old captures, prove a fix, or trigger a rescan.
7. **Finish explicitly:** use `:ReviewDone` in Neovim, or `/review-done` in the
   originating Pi conversation. Done submits no drafts. It may run a tool-free
   wrap-up turn and durably records completion and a bounded summary; it does not
   perform a new source scan, run tests or authorize implementation. Editor Done
   does not inject the summary into the parent Pi conversation.

### Feedback and report inspection

Notifications distinguish durable acceptance from final completion/failure.
For statuslines/widgets, `require('parley').request_status()` returns a copied
cached observation; reading it performs no transport/model work.

Explicitly open the latest acknowledged review request's report with:

```vim
:lua require('parley').request_report()
```

The read-only Markdown float separates submitted scope, observed outcomes,
publication/application/receipt facts and reviewer-reported coverage, conclusion,
verification and limitations. `q` or `<Esc>` closes it. Opening/reopening starts
no retrieval or model turn; reports never open automatically. Missing explanation
means **not recorded**; lost final delivery means **final outcome not received**.
This is a cached latest-request view, not a browser of saved requests.

- Zero findings is valid, but is not approval, exhaustive coverage or successful
  verification. Failed/cancelled requests may still have published partial work.
- Publication is not editor application. Applied history may remain unplaced;
  incompatible history is not retargeted. A recorded receipt preserves the
  editor's application/incompatibility and placement report at that time, not a
  verified fix or a claim about current source. Missing receipts mean unknown.
- For an explicit parent-side evidence pickup, ask the originating Pi conversation
  to use `parley_pickup`. It reads bounded samples and an artifact reference after
  settlement, with omissions labelled. It does not apply, replay or end a review.

### Stop, Done and a fresh review

| Action | Effect |
| --- | --- |
| `:ReviewStop` | Detach Neovim presentation/pairing; retain local notes and drafts; do not cancel Pi work |
| `/review-stop [review-id]` | Withdraw the current exact-owned review and cancel running work; no wrap-up or rollback. Optional ID is a stale-identity check, not a review selector |
| `:ReviewDone [review-id]` / `/review-done [review-id]` | Explicit wrap-up, or read the saved summary of a completed review still retained by this live owner; never regenerate a completed summary |

Pi-side Stop and Done reject incompatible initialization, preparation, upload or settlement
races rather than queueing them. A stopped review is not resumable execution.
Neither stop nor completion deletes existing evidence or local drafts.

After Done or Pi-side Stop, run `/review` for a fresh review, optionally prepare
it, then run `:ReviewStart` explicitly to select it. Old notes/drafts remain in
separate identity-bound sets in the same Neovim process; they are not submitted
or migrated into the new review. Repeating `/review` on an open review reuses its
offer rather than silently starting a fresh one.

## Standalone implementation with Parley

This manual path does not require a preceding review. Complete or withdraw any
open review first; review and implementation cannot own execution concurrently.

1. Run `/parley` without arguments in the idle originating Pi session. The parent
   enters a waiting host tool; the independent child retains branched context and
   a detailed transcript. Do not issue unrelated parent work while it is hosted.
2. Run `:ParleyStart` in Neovim to pair. Pairing alone submits nothing.
3. Compose explicit implementation instructions beside the code. **Save or
   reconcile all modified workspace source buffers before each `:ParleyTurn`.**
   A turn submits eligible new prose across all unresolved conversations, not the
   entire inherited plan. The normal child can edit the shared workspace and
   publish replies into the submitted conversations.
4. Use `:ParleyResolve` to exclude the selected conversation from future turns,
   or `:ParleyReopen` to include it again. Both preserve drafts/history and submit
   nothing. Resolution is only a local turn filter, not approval or verification.
5. Run `:ParleyDone` to finish and return a durable recap to the exact originating
   Pi parent. Detailed work remains in the child transcript. The recap does not
   apply edits: they already exist in the shared workspace.

`:ParleyStop` only detaches Neovim, like `:ReviewStop`; it does not finish or cancel
implementation. To stop the hosted interaction, use `/parley-stop` without
arguments in the originating Pi session. It cancels running work and retains
edits/transcripts without rollback or a Done recap; incompatible lifecycle races
are rejected, not queued.

A linked review-to-implementation handoff is optional and deferred. There is no
automatic conversion or dedicated handoff command; standalone `/parley` is a
separate, explicitly chosen workflow.

## Default local controls

| Context | Keys | Action |
| --- | --- | --- |
| Source | `c` (Normal/Visual) | Compose a line/range note |
| Source | `C` | Resume or compose a note |
| Source | `<CR>` | Enter the selected/overlapping note |
| Source | `<C-n>` / `<C-p>` | Visit next/previous local note; explicit navigation may open source |
| Thread reader | `<C-n>` / `<C-p>`, `za` | Move between messages, toggle folding |
| Thread reader | `r`, `e` / `<CR>`, `q` / `<Esc>` | Reply, edit, close |
| Composer | `<CR>`, Normal `q` | Accept locally and leave the composer/thread as appropriate |
| Composer | `<C-c>` | Close while retaining unfinished edits |
| Composer | Insert `<C-j>` / `<C-CR>`, Normal `<leader>?` | Insert newline, toggle contextual help |

**Save, close and Enter never submit an agent request.** Submit discussion or
investigation turns explicitly with Ask, Investigate or Turn; Done is the separate
wrap-up action described above. Key choices can be configured with `setup()`
before activating review mode; configuration, not Parley, owns your layout.

## Persistence and limits

Pi writes append-only JSONL outside the workspace, under
`$XDG_STATE_HOME/parley/reviews/` (default `~/.local/state/parley/reviews/`),
or the sibling `parleys/` directory for implementation.
`PARLEY_STATE_DIR` overrides that state root and must resolve outside the workspace.
Records preserve identities, baseline/provenance, captured snippets, submitted
history/revisions, outcomes, application receipts, recorded explanations and
completion summaries. SDK transcripts are separate referenced files.

These files support read-only offline analytics, but are not full repository or
transcript bundles. Token/cost accounting and exhaustive discovery/coverage are
not guaranteed artifact data. Treat captured source, prose and local paths as
potentially sensitive when sharing.

Draft buffers, native undo, local resolution flags, current placement and cached
reports/status are editor-process state, not restart persistence. There is no
saved-history viewer, automatic draft restoration, selected/full readable export,
reopen-for-append, automatic repair, replay or ownership migration. Disconnects
never authorize replay of uncertain application. Persisted evidence surviving a
restart does not mean the UI or execution can reopen it. Parley does not check
out revisions or restore original source over a changed working copy.
