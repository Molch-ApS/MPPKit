# Changelog

Each release is also on [GitHub](https://github.com/Molch-ApS/MPPKit/releases),
with every pull request in it. Releases before 0.6.0 are described only there.

## 0.6.0

### Breaking change

`Baseline.cost` is now in currency units, as `ProjectTask.cost`,
`Assignment.cost`, `Resource.cost`, `fixedCost` and the pay rates already are.
Before, it held hundredths, as the file stores them. Code that read or set
`Baseline.cost` must stop dividing or multiplying by 100. The reader and the
writer convert, and an unchanged baseline still keeps Project's own bytes.

### Added

- Costs: standard and overtime rates, cost per use, cost rate tables A to E
  with their dates, fixed cost and its accrual, and the costs Project
  calculated are read, and worked out again on save where something they depend
  on changed (#27).
- Split tasks are read with their gaps (`ProjectTask.splits`), keep them when
  edited, and the gaps move with the task (#26).
- Set Baseline copies cost, and an assignment's work as the file holds it.
  `setBaseline`, `keepPlan`, `saveNewBaseline` and `updateBaseline` take the
  plan as it was read (`keepingFrom:`, default `nil`) (#28).

### Fixed

- Scheduler: a lag runs in the successor's calendar on the backward pass too
  (#24); a started task's remaining part moves after a predecessor that moves
  later (#40).
- Writer: a save with no edits keeps each assignment's work (#30); a start a
  link produces is not pinned with Start No Earlier Than (#31); a summary's
  % complete is its bottom tasks' by duration (#37); manually scheduled tasks
  in older files keep their mode, dates and duration (#38).
- Calendars: found by uid, not name (#29); a project calendar other than
  Standard keeps its own row (#33); resources keep their own calendars, and
  unchanged base calendars keep their bytes (#36).
- Reader: spare FixedMeta items keep the item size, and late dates are read as
  Project writes them (#25).
- Custom properties: new values take values' ids (#20), and text outside the
  section's code page is kept (#23). Outline code values are named by their
  uid (#22). A task added after tasks deleted in Project is saved (#21).
