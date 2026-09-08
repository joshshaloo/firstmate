#!/usr/bin/env bash
# fm-backlog-parse-lib.sh - the single owner of firstmate's backlog row syntax.
#
# One parser reads BOTH durable queue files, because they share one row syntax:
#   data/backlog.md       - the live queue, sections "## In flight", "## Queued", "## Done"
#   data/done-archive.md  - the overflow Done retention drops (.tasks.toml done_keep),
#                           sections "## Archived <YYYY-MM-DD>"
# An "Archived" section is a done section that also carries its own archive date, so a
# reader spanning a time window can date a row the writer left undated.
#
# fm_backlog_json <path> [<today>] emits:
#   {path, present, records[]}
# with records ordered as written. Each structured record carries id, state
# (in_flight|queued|done), title, repo, kind, priority, hold_*, blocked_*, since,
# completion{verb,date}, section_date, closed_on, links[], pr_url, report_path,
# local_note, raw, body_excerpt, body_links[], body_pr_url, unresolved_blocker_ids,
# current_role, requires_child_metadata, captain_actionable, and deferred_marker.
# pr_url and body_pr_url cover both supported forges: GitHub /pull/<n> and
# Bitbucket /pull-requests/<n>, with trailing sentence punctuation stripped.
# An unparseable line under a known section is kept as a structured:false record so
# nothing is silently dropped.
#
# closed_on is the row's own completion date when it has one, else the enclosing
# archive section's date, else null. It is the only date a windowed read may trust:
# firstmate writes it at close time, so it survives retention and archiving.
#
# <today> defaults to the current UTC date and only drives captain_actionable's
# hold-until comparison.
#
# Requires jq. Read-only: no locks, no mutation.

fm_backlog_json() {  # <backlog-path> [<today>]
  local backlog=$1 today=${2:-}
  [ -n "$today" ] || today=$(date -u +%Y-%m-%d)
  if [ ! -f "$backlog" ]; then
    jq -n --arg path "$backlog" '{path:$path,present:false,records:[]}'
    return 0
  fi

  # shellcheck disable=SC2094
  jq -Rn --arg path "$backlog" --arg today "$today" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def section_state:
      if . == "In flight" then "in_flight"
      elif . == "Queued" then "queued"
      elif . == "Done" then "done"
      elif test("^Archived([[:space:]]|$)") then "done"
      else null end;
    def section_date:
      (capture("^Archived[[:space:]]+(?<v>[0-9]{4}-[0-9]{2}-[0-9]{2})")? // {} | .v) // null;
    def cap($rest; $re):
      (((($rest | capture($re)?) // {}) | .v) // null) as $v
      | if $v == null then null else ($v | trim) end;
    def metadata($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + ":[[:space:]]*(?<v>[^,)]*)");
    def metadata_word($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + "[[:space:]]+(?<v>[^,)]*)");
    def url_pattern: "https?://[^[:space:])\"<>]+";
    # Prose commonly ends a sentence right after a URL. Strip that trailing
    # punctuation from every emitted link so a PR URL stays clickable, while
    # url_pattern itself stays greedy for the title-stripping gsub above.
    def clean_url: sub("[,.;:]+$"; "");
    def pr_link: map(select(test("/pull/[0-9]+|/pull-requests/[0-9]+"))) | .[0];
    def wrapped_url_pattern: "<?" + url_pattern + ">?";
    def links($rest): [$rest | scan(url_pattern) | clean_url];
    def strip_trailing_metadata:
      reduce range(0; 20) as $_ (.;
        sub("[[:space:]]*\\([[:space:]]*(?:(?:repo|kind|priority|hold|hold-kind|hold-until):[[:space:]]*[^)]*|(?:since|merged|reported|done)[[:space:]]+[^)]*)[[:space:]]*\\)[[:space:]]*$"; ""));
    def strip_title_artifacts:
      sub("[[:space:]]+-[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+-[[:space:]]+local main$"; "")
      | sub("[[:space:]]+local main$"; "")
      | sub("[[:space:]]+-[[:space:]]*$"; "");
    def clean_title:
      strip_trailing_metadata
      | strip_title_artifacts
      | gsub("[[:space:]]+"; " ")
      | trim;
    def title_of($rest):
      $rest
      | gsub(wrapped_url_pattern; "")
      | sub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:])]+[[:space:]]+-[[:space:]]+.*$"; "")
      | gsub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:]]+"; "")
      | clean_title;
    def blocked_by_ids($rest):
      [ $rest | scan("blocked-by:[[:space:]]+(?<id>[^[:space:])]+)") | .[0] ]
      | reduce .[] as $id ([]; if index($id) == null then . + [$id] else . end);
    def blocked_reason($rest):
      cap($rest; ".*blocked-by:[[:space:]]*[^[:space:])]+[[:space:]]+-[[:space:]]*(?<v>.*)$") as $reason
      | if $reason == null then null
        else ($reason | clean_title | if . == "" then null else . end)
        end;
    def local_note($rest):
      cap(($rest | strip_trailing_metadata); ".*(?:^|[[:space:]]+-[[:space:]]+|[[:space:]])(?<v>local main)$");
    # A completion marker is "(<verb> YYYY-MM-DD)". Requiring the date shape here
    # matters: title prose routinely contains the bare word "merged" or "done", and
    # a captured sentence fragment would then sort landed work by nonsense and hand
    # a windowed reader a close date that is not a date at all.
    def completion_date($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key
                 + "[[:space:]]+(?<v>[0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]*[,)]");
    def completion($rest):
      (completion_date($rest; "merged")) as $merged
      | (completion_date($rest; "reported")) as $reported
      | (completion_date($rest; "done")) as $done
      | if $merged != null then {verb:"merged",date:$merged}
        elif $reported != null then {verb:"reported",date:$reported}
        elif $done != null then {verb:"done",date:$done}
        else {verb:null,date:null} end;
    def row_match($line):
      (($line | capture("^[-*][[:space:]]+\\[(?<check>[ xX])\\][[:space:]]+(?<id>[^[:space:]]+)[[:space:]]+-[[:space:]]+(?<rest>.*)$")?) //
       (($line | capture("^[-*][[:space:]]+\\*\\*(?<id>[^*]+)\\*\\*[[:space:]]+-[[:space:]]+(?<rest>.*)$")?)
        | if . == null then null else . + {check:" "} end));
    def structured_row($line):
      ($line | test("^[-*][[:space:]]+\\[[ xX]\\][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+"))
      or ($line | test("^[-*][[:space:]]+\\*\\*[^*]+\\*\\*[[:space:]]+-[[:space:]]+"));
    def parse_row($line; $section; $section_date; $order):
      row_match($line) as $m
      | if $m == null then
          {order:$order,state:$section,section_date:$section_date,structured:false,id:null,
           closed_on:$section_date,raw:$line,body_lines:[],body_excerpt:null}
        else
          ($m.rest) as $rest
          | {order:$order,
             state:$section,
             section_date:$section_date,
             structured:true,
             id:($m.id | trim),
             checked:($m.check | test("[xX]")),
             title:title_of($rest),
             repo:metadata($rest; "repo"),
             kind:metadata($rest; "kind"),
             priority:metadata($rest; "priority"),
             hold_reason:metadata($rest; "hold"),
             hold_kind:metadata($rest; "hold-kind"),
             hold_until:metadata($rest; "hold-until"),
             blocked_by:cap($rest; ".*blocked-by:[[:space:]]*(?<v>[^[:space:])]+).*"),
             blocked_by_ids:blocked_by_ids($rest),
             blocked_reason:blocked_reason($rest),
             since:metadata_word($rest; "since"),
             merged:metadata_word($rest; "merged"),
             reported:metadata_word($rest; "reported"),
             done:metadata_word($rest; "done"),
             completion:completion($rest),
             closed_on:((completion($rest) | .date) // $section_date),
             links:links($rest),
             pr_url:((links($rest) | pr_link) // null),
             report_path:cap($rest; ".*(?<v>data/[^[:space:])]+/report\\.md).*"),
             local_note:local_note($rest),
             raw:$line,
             body_lines:[],
             body_excerpt:null}
        end;
    reduce inputs as $line
      ({path:$path,present:true,records:[],section:null,section_date:null,order:0};
       if ($line | test("^##[[:space:]]+")) then
         (($line | sub("^##[[:space:]]+";"") | trim)) as $heading
         | .section = ($heading | section_state)
         | .section_date = ($heading | section_date)
       elif .section == null or ($line | trim) == "" then
         .
       elif structured_row($line) then
         .order += 1
         | .records += [parse_row($line; .section; .section_date; .order)]
       elif ((.records | length) > 0 and (.records[-1].structured == true) and ($line | test("^[[:space:]]+"))) then
         ($line | trim) as $body
         | if $body == "" then .
           else .records[-1].body_lines += [$body] end
       else
         .order += 1
         | .records += [{order:.order,state:.section,section_date:.section_date,structured:false,
                         id:null,closed_on:.section_date,raw:$line,body_lines:[],body_excerpt:null}]
       end)
    | .records |= map(
        if (.body_lines | length) > 0 then
          ((.body_lines | join(" "))) as $body
          | .body_excerpt = ($body[:240])
          | .body_links = [$body | scan(url_pattern) | clean_url]
          | .body_pr_url = ((.body_links | pr_link) // null)
        else (.body_links = []) | .body_pr_url = null end)
    | .records as $records
    | (reduce ($records[] | select(.structured)) as $record ({};
         .[$record.id] = ((.[$record.id] // true) and ($record.state == "done")))) as $resolved_ids
    | .records |= map(
        if .structured then
          . as $record
          | .unresolved_blocker_ids = [
              $record.blocked_by_ids[] as $blocker
              | select($resolved_ids[$blocker] != true)
              | $blocker
            ]
          | .current_role =
              (if .state == "in_flight" and .hold_reason != null and .hold_kind != null then "held"
               elif .state == "in_flight" and .kind == "program" then "program"
               elif .state == "in_flight" then "worker"
               elif .state == "queued" then "queued"
               else "done" end)
          | .requires_child_metadata = (.current_role == "worker")
          | .captain_actionable =
              (.state == "queued" and .kind == "captain" and .hold_kind == "captain"
               and .hold_reason != null and (.unresolved_blocker_ids | length) == 0
               and (.hold_until == null or .hold_until <= $today))
          | .deferred_marker =
              ((((.hold_reason // "") + " " + (.body_excerpt // ""))
                | test("SUPERSEDED|NOT REQUIRED|NOT-REQUIRED|DEFERRED"; "i")))
        else . end)
    | del(.section,.section_date,.order)
  ' < "$backlog"
}
