#!/bin/bash
# MPPKit: Microsoft Project (.mpp) files in Swift
# Copyright (C) 2026 Henrik Petersen
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License version 3 as
# published by the Free Software Foundation. It is distributed WITHOUT ANY
# WARRANTY; see the LICENSE file for details. https://mppstudio.com
#
# SPDX-License-Identifier: AGPL-3.0-only
#
# Download the Project 2010/2013 files from MPXJ's test corpus into a folder
# (default Corpus/), for ConformanceTests and `mppdump check`. Each was saved
# by Microsoft Project itself, so they show what Project writes — the
# shipped samples were written by MPPKit and cannot. They are fetched at a
# pinned MPXJ commit rather than kept in this repository.
#
#   Tools/ci/fetch-corpus.sh [dir]
set -euo pipefail
commit=acc66da5f16be803d6a893faa8ab80e76f94e012
dir=${1:-Corpus}
files=(
    mpp14assignmentcustom.mpp
    mpp14assignmentfields.mpp
    mpp14autofilter.mpp
    mpp14availability.mpp
    mpp14barstyle.mpp
    mpp14baseline.mpp
    mpp14baselines.mpp
    mpp14calendar.mpp
    mpp14columns.mpp
    mpp14costratetable.mpp
    mpp14duration.mpp
    mpp14embedded.mpp
    mpp14enterprise.mpp
    mpp14exceptions.mpp
    mpp14filterlogic.mpp
    mpp14filter.mpp
    mpp14gantt.mpp
    mpp14graphind.mpp
    mpp14group.mpp
    mpp14header.mpp
    mpp14nulltasks.mpp
    mpp14recurring.mpp
    mpp14relations.mpp
    mpp14resource.mpp
    mpp14splittask.mpp
    mpp14subproject.mpp
    mpp14task-from2013.mpp
    mpp14task.mpp
    mpp14timephased2.mpp
    mpp14timephased.mpp
    mpp14timephasedsegmentsmanual.mpp
    mpp14timephasedsegmentsmanualoffsets.mpp
    mpp14timephasedsegments.mpp
    mpp14viewstate.mpp
    ResourceIdAndUniqueId-project2010-mpp14.mpp
    ResourceIdAndUniqueId-project2013-mpp14.mpp
    generated/task-outlinecodes/task-outlinecodes-project2010-mpp14.mpp
    generated/task-outlinecodes/task-outlinecodes-project2013-mpp14.mpp
)
# And the Microsoft Project XML (MSPDI) files Project 2002-2019 saved:
# MSPDITests reads each with MPPKit's own XML reader and holds the tree to
# the one Foundation's XMLParser builds.
files+=(
    PredecessorCalendar.xml
    ProjectDefaultCalendar.xml
    SuccessorCalendar.xml
    TwentyFourHourCalendar.xml
    assignment/resource-rates-test.xml
    baselines.xml
    enterprise.xml
    generated/assignment-assignments/assignment-assignments-project2002-mspdi.xml
    generated/assignment-assignments/assignment-assignments-project2003-mspdi.xml
    generated/assignment-assignments/assignment-assignments-project2007-mspdi.xml
    generated/assignment-assignments/assignment-assignments-project2010-mspdi.xml
    generated/assignment-assignments/assignment-assignments-project2013-mspdi.xml
    generated/assignment-assignments/assignment-assignments-project2016-mspdi.xml
    generated/assignment-assignments/assignment-assignments-project2019-mspdi.xml
    generated/assignment-flags/assignment-flags-project2003-mspdi.xml
    generated/assignment-flags/assignment-flags-project2007-mspdi.xml
    generated/assignment-flags/assignment-flags-project2010-mspdi.xml
    generated/assignment-flags/assignment-flags-project2013-mspdi.xml
    generated/assignment-flags/assignment-flags-project2016-mspdi.xml
    generated/assignment-flags/assignment-flags-project2019-mspdi.xml
    generated/assignment-text/assignment-text-project2002-mspdi.xml
    generated/assignment-text/assignment-text-project2003-mspdi.xml
    generated/assignment-text/assignment-text-project2007-mspdi.xml
    generated/assignment-text/assignment-text-project2010-mspdi.xml
    generated/assignment-text/assignment-text-project2013-mspdi.xml
    generated/assignment-text/assignment-text-project2016-mspdi.xml
    generated/assignment-text/assignment-text-project2019-mspdi.xml
    generated/calendar-calendars/calendar-calendars-project2002-mspdi.xml
    generated/calendar-calendars/calendar-calendars-project2003-mspdi.xml
    generated/calendar-calendars/calendar-calendars-project2007-mspdi.xml
    generated/calendar-calendars/calendar-calendars-project2010-mspdi.xml
    generated/calendar-calendars/calendar-calendars-project2013-mspdi.xml
    generated/calendar-calendars/calendar-calendars-project2016-mspdi.xml
    generated/calendar-calendars/calendar-calendars-project2019-mspdi.xml
    generated/calendar-recurring-exceptions/calendar-recurring-exceptions-project2007-mspdi.xml
    generated/calendar-recurring-exceptions/calendar-recurring-exceptions-project2010-mspdi.xml
    generated/calendar-recurring-exceptions/calendar-recurring-exceptions-project2013-mspdi.xml
    generated/calendar-recurring-exceptions/calendar-recurring-exceptions-project2016-mspdi.xml
    generated/resource-flags/resource-flags-project2002-mspdi.xml
    generated/resource-flags/resource-flags-project2003-mspdi.xml
    generated/resource-flags/resource-flags-project2007-mspdi.xml
    generated/resource-flags/resource-flags-project2010-mspdi.xml
    generated/resource-flags/resource-flags-project2019-mspdi.xml
    generated/resource-misc/resource-misc-project2002-mspdi.xml
    generated/resource-misc/resource-misc-project2003-mspdi.xml
    generated/resource-misc/resource-misc-project2007-mspdi.xml
    generated/resource-misc/resource-misc-project2010-mspdi.xml
    generated/resource-misc/resource-misc-project2019-mspdi.xml
    generated/resource-numbers/resource-numbers-project2002-mspdi.xml
    generated/resource-numbers/resource-numbers-project2003-mspdi.xml
    generated/resource-numbers/resource-numbers-project2007-mspdi.xml
    generated/resource-numbers/resource-numbers-project2010-mspdi.xml
    generated/resource-numbers/resource-numbers-project2019-mspdi.xml
    generated/resource-text/resource-text-project2002-mspdi.xml
    generated/resource-text/resource-text-project2003-mspdi.xml
    generated/resource-text/resource-text-project2007-mspdi.xml
    generated/resource-text/resource-text-project2010-mspdi.xml
    generated/resource-text/resource-text-project2019-mspdi.xml
    generated/resource-type/resource-type-project2002-mspdi.xml
    generated/resource-type/resource-type-project2003-mspdi.xml
    generated/resource-type/resource-type-project2007-mspdi.xml
    generated/resource-type/resource-type-project2010-mspdi.xml
    generated/resource-type/resource-type-project2013-mspdi.xml
    generated/resource-type/resource-type-project2016-mspdi.xml
    generated/task-baselines/task-baselines-project2002-mspdi.xml
    generated/task-baselines/task-baselines-project2003-mspdi.xml
    generated/task-baselines/task-baselines-project2007-mspdi.xml
    generated/task-baselines/task-baselines-project2010-mspdi.xml
    generated/task-baselines/task-baselines-project2013-mspdi.xml
    generated/task-baselines/task-baselines-project2016-mspdi.xml
    generated/task-baselines/task-baselines-project2019-mspdi.xml
    generated/task-costs/task-costs-project2003-mspdi.xml
    generated/task-costs/task-costs-project2007-mspdi.xml
    generated/task-costs/task-costs-project2010-mspdi.xml
    generated/task-costs/task-costs-project2013-mspdi.xml
    generated/task-costs/task-costs-project2016-mspdi.xml
    generated/task-costs/task-costs-project2019-mspdi.xml
    generated/task-dates/task-dates-project2003-mspdi.xml
    generated/task-dates/task-dates-project2007-mspdi.xml
    generated/task-dates/task-dates-project2010-mspdi.xml
    generated/task-dates/task-dates-project2013-mspdi.xml
    generated/task-dates/task-dates-project2016-mspdi.xml
    generated/task-dates/task-dates-project2019-mspdi.xml
    generated/task-durations/task-durations-project2003-mspdi.xml
    generated/task-durations/task-durations-project2007-mspdi.xml
    generated/task-durations/task-durations-project2010-mspdi.xml
    generated/task-durations/task-durations-project2013-mspdi.xml
    generated/task-durations/task-durations-project2016-mspdi.xml
    generated/task-durations/task-durations-project2019-mspdi.xml
    generated/task-finishes/task-finishes-project2003-mspdi.xml
    generated/task-finishes/task-finishes-project2007-mspdi.xml
    generated/task-finishes/task-finishes-project2010-mspdi.xml
    generated/task-finishes/task-finishes-project2013-mspdi.xml
    generated/task-finishes/task-finishes-project2016-mspdi.xml
    generated/task-finishes/task-finishes-project2019-mspdi.xml
    generated/task-flags/task-flags-project2003-mspdi.xml
    generated/task-flags/task-flags-project2007-mspdi.xml
    generated/task-flags/task-flags-project2010-mspdi.xml
    generated/task-flags/task-flags-project2013-mspdi.xml
    generated/task-flags/task-flags-project2016-mspdi.xml
    generated/task-flags/task-flags-project2019-mspdi.xml
    generated/task-links/task-links-project2003-mspdi.xml
    generated/task-links/task-links-project2007-mspdi.xml
    generated/task-links/task-links-project2010-mspdi.xml
    generated/task-links/task-links-project2013-mspdi.xml
    generated/task-links/task-links-project2016-mspdi.xml
    generated/task-links/task-links-project2019-mspdi.xml
    generated/task-numbers/task-numbers-project2003-mspdi.xml
    generated/task-numbers/task-numbers-project2007-mspdi.xml
    generated/task-numbers/task-numbers-project2010-mspdi.xml
    generated/task-numbers/task-numbers-project2013-mspdi.xml
    generated/task-numbers/task-numbers-project2016-mspdi.xml
    generated/task-numbers/task-numbers-project2019-mspdi.xml
    generated/task-starts/task-starts-project2003-mspdi.xml
    generated/task-starts/task-starts-project2007-mspdi.xml
    generated/task-starts/task-starts-project2010-mspdi.xml
    generated/task-starts/task-starts-project2013-mspdi.xml
    generated/task-starts/task-starts-project2016-mspdi.xml
    generated/task-starts/task-starts-project2019-mspdi.xml
    generated/task-text/task-text-project2003-mspdi.xml
    generated/task-text/task-text-project2007-mspdi.xml
    generated/task-text/task-text-project2010-mspdi.xml
    generated/task-text/task-text-project2013-mspdi.xml
    generated/task-text/task-text-project2016-mspdi.xml
    generated/task-text/task-text-project2019-mspdi.xml
    generated/task-textvalues/task-textvalues-project2010-mspdi.xml
    generated/task-textvalues/task-textvalues-project2013-mspdi.xml
    generated/task-textvalues/task-textvalues-project2016-mspdi.xml
    generated/task-textvalues/task-textvalues-project2019-mspdi.xml
    legacy/alias.xml
    legacy/caltest.xml
    legacy/headertest9.xml
    legacy/mspdipriority.xml
    legacy/mspextattr.xml
    legacy/sample.xml
    legacy/sample1.xml
    mspdiassignmentcustom.xml
    mspdiassignmentfields.xml
    mspdiavailability.xml
    mspdicostratetable.xml
    mspdiduration.xml
    mspdinulltasks.xml
    mspdirelations.xml
    mspdiresource.xml
    mspdisplittask.xml
    mspditimephased.xml
    mspditimephasedsegments.xml
    project/default-duration-format/DefaultDurationFormat.xml
)
mkdir -p "$dir"
for f in "${files[@]}"; do
    out="$dir/$(basename "$f")"
    [[ -s "$out" ]] && continue
    curl -fsSL --retry 3 -o "$out" "https://raw.githubusercontent.com/joniles/mpxj/$commit/junit/data/$f"
done
echo "${#files[@]} Project-saved files in $dir"
