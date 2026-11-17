# MSCatalogLTS 
PowerShell Module for Windows Updates

[![PSGallery Version](https://img.shields.io/powershellgallery/v/MSCatalogLTS.svg?style=flat&logo=powershell&label=PSGallery%20Version)](https://www.powershellgallery.com/packages/MSCatalogLTS) [![PSGallery Downloads](https://img.shields.io/powershellgallery/dt/MSCatalogLTS.svg?style=flat&logo=powershell&label=PSGallery%20Downloads)](https://www.powershellgallery.com/packages/MSCatalogLTS) [![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue?style=flat&logo=powershell)](https://www.powershellgallery.com/packages/MSCatalogLTS) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> **Long-term support PowerShell module** for searching, filtering, and downloading Windows updates from the Microsoft Update Catalog

MSCatalogLTS is a **cross-platform PowerShell module** that provides an easy-to-use interface for interacting with the [Microsoft Update Catalog](https://www.catalog.update.microsoft.com). Whether you need to download cumulative updates, security patches, or manage offline updates for Windows 10, Windows 11, or Windows Server, MSCatalogLTS makes it simple.

---

## ⚡Key Features

- 🔍 **Search Windows Updates** - Find cumulative updates, security patches, drivers, and more
- ⬇️ **Download Updates Offline** - Download .msu, .cab, and other update files directly
- 🖥️ **Cross-Platform Support** - Works on Windows PowerShell 5.1+ and PowerShell 7+ (Core)
- 🧠 **Smart Filtering** - Filter by date, size, architecture (x64, x86, arm64), product, and classification
- 📦 **Export to Multiple Formats** - Export results to CSV, JSON, XML, or Excel
- 🔧 **Pipeline Support** - Full PowerShell pipeline integration for automation
- 🛡️ **Long-Term Support** - Actively maintained with regular updates and bug fixes
- 📊 **Batch Operations** - Process multiple updates efficiently

---

## 📦 Quick Install

### Install from PowerShell Gallery

```powershell
Install-Module -Name MSCatalogLTS -Scope CurrentUser
```

### Update to Latest Version

```powershell
Update-Module -Name MSCatalogLTS
```

### Verify Installation

```powershell
Get-Module -ListAvailable MSCatalogLTS
```

---

## 💡 Quick Start Examples

### Search Text and Catalog Products

```powershell
# Free-text Catalog search
Get-MSCatalogUpdate -Search "Cumulative Update"

# Product-only candidate search, followed by exact product filtering
Get-MSCatalogUpdate -Product "Microsoft Server Operating System-24H2" -AllPages

# Free-text search AND exact product filtering
Get-MSCatalogUpdate -Search "Cumulative Update" -Product "Microsoft Server Operating System-24H2" -AllPages

# Short Catalog query with an optional, independent title phrase
Get-MSCatalogUpdate `
    -Search "Cumulative Update for .NET Framework 3.5 and 4.8.1 server 24H2 x64" `
    -TitleContains "Cumulative Update for .NET Framework 3.5 and 4.8.1" `
    -Product "Microsoft Server Operating System-24H2" `
    -Architecture x64 -ToDate "2026-11-30" -ExcludeSuperseded -AllPages
```

`-Search` uses the Catalog's free-text search, including its existing smart OS
query handling. The search text does not have to occur as a complete phrase in
the title. No additional local title comparison is performed unless
`-TitleContains` is specified; the existing OS, update-type and other filters
still apply.

`-TitleContains` (alias `-TitelContains`) is an optional local title filter. Its
complete phrase must occur in the title, ignoring case. Punctuation and spaces
are literal; wildcards are not expanded. HTML title entities are decoded for the
comparison. For example, `-TitleContains "operating system 24H2"` does not match
`operating system version 24H2`. Omit the filter to keep the Catalog candidates,
or use a shorter phrase such as `.NET Framework 3.5 and 4.8.1`.

The title phrase is not sent to the Catalog and does not increase the query
length. It works with `-Search`, product-only and structured OS searches, on all
retrieved pages, before supersedence and download metadata retrieval. It must be
combined with a search source (`-Search`, `-Product` or `-OperatingSystem`);
empty, null and whitespace-only title phrases are rejected. A title match does
not imply that the **Products** column contains a particular product.

`-Product` filters the actual **Products** column for a complete, case-insensitive
product name. An update associated with several products matches if any individual
association equals the requested name. Substrings and wildcards do not match.
HTML entities are decoded and display whitespace is normalized when matching;
commas inside product names are retained. The existing `Products` output property
remains a string. Parsing follows the Catalog's current HTML delimiter convention
(one space after association commas, two after commas within names); a change to
that rendering may require a parser update. Use the name displayed in the Catalog: for example,
`Microsoft Server Operating System-24H2`, rather than the commercial name
`Windows Server 2025`. This parameter introduces no commercial-name mapping.

Supply at least one of `-Search` or `-Product`, or use the existing
`-OperatingSystem` parameter set. Explicitly empty, null, or whitespace-only search
and product values are rejected. `-Product` also works with `-OperatingSystem`
and `-Version`. All existing filters still apply, including architecture,
classification, date, preview, and Framework filters. Product filtering runs before
supersedence metadata lookup and exclusion, so a replacement associated only with
another product cannot remove a selected update. `-ExcludeSupersedence` is accepted
as an alias for the existing `-ExcludeSuperseded` switch.

**Product-only limitations:** The public Catalog search interface does not expose
a separate exact-product query or a guaranteed product-enumeration endpoint.
Without `-Search`, the module sends the literal product name as a free-text query
to discover candidates, then filters their Products column. It does not apply the
smart OS parser, phrase quoting (`-Strict`), or inject title/date terms into that
candidate query. Date and other filters still apply locally. This is not a
guarantee of every update associated with the product; product-only calls always
emit a warning explaining the limitation.

Pagination retains the existing behavior: one candidate page by default, or up to
40 pages with `-AllPages`. The Catalog returns at most 1,000 candidates per query;
`-AllPages` cannot bypass that cap. Product filtering may leave fewer results, or
none, on a page even when later pages contain matches. With `-Product`, omitted
pages and Catalog limit notices produce warnings **before** local filtering.
`-Search` can narrow the candidate query; local date filters cannot recover
candidates beyond the Catalog cap. The module does not crawl other queries to
work around this limit. Defaults still exclude dynamic and preview updates; use
their existing inclusion switches when needed.

These behaviors are based on the public [Catalog FAQ](https://www.catalog.update.microsoft.com/Faq.aspx)
and [Catalog search interface](https://www.catalog.update.microsoft.com/Search.aspx?q=Microsoft%20Server%20Operating%20System-24H2).

### Retrieve Download URLs Without Downloading Files

```powershell
$updates = Get-MSCatalogUpdate `
    -Product "Microsoft Server Operating System-24H2" `
    -Architecture x64 -ExcludeSupersedence -IncludeDownloadUrls

$updates | Select-Object Guid, Title, Downloads
$updates | ForEach-Object { $_.Downloads } | Format-Table Url, FileName, KB, SHA1
```

`-IncludeDownloadUrls` adds one Catalog DownloadDialog request for each unique
update GUID remaining after all filters, including supersedence exclusion. It
works with free-text, product and operating-system searches and independently of
`-IncludeSupersedence` and `-ExcludeSupersedence`. Pagination is unchanged. It
retrieves metadata only: **no files are downloaded**.

Every update has a `Downloads` property. Without the switch (or with
`-IncludeDownloadUrls:$false`), it is `$null` and no requests for this metadata are
made. The existing `-IncludeFileNames` option still makes its own requests when
used alone; with both switches, requests are shared and deferred until filtering
is complete.

| Download entry property | Value |
|---|---|
| `Url` | Absolute HTTP or HTTPS download URL. Duplicate URLs appear once. |
| `FileName` | Full original filename from the URL path, with URL escaping decoded; names are never shortened. |
| `KB` | KB identifier (for example, `KB5078127`) when supplied by the link metadata; otherwise `$null`. |
| `SHA1` | Uppercase 40-character hexadecimal SHA-1 digest, converted from Base64 when needed; `$null` if absent. |

With `-IncludeDownloadUrls`, the existing update-level `SHA1` property is also
populated from the first entry in `Downloads`. It remains blank if that entry has
no digest or the response contains no files. For updates with multiple files,
inspect `Downloads` for each file's digest; the update-level value represents only
the first file. This reuses the same metadata without an additional request.

With the switch enabled, single-file updates still have a collection; a successful response with no files
has an empty collection. Entries are ordered by Catalog download-information and
file indexes, retaining the first occurrence of each URL. HTTP failures,
unrecognized or incomplete responses, malformed URLs and invalid checksums cause
a terminating error identifying the affected update GUID. A technical failure
does not return a partial download list. JSON and XML output retain the nested
metadata. Default table columns remain unchanged; select or expand `Downloads`
to inspect the entries.

### Example 1: Search for Windows 11 Updates

```powershell
Get-MSCatalogUpdate -Search "Windows 11 24H2 x64"
```

**Output:**
```
Search completed for: Cumulative Update for Windows 11 Version 24H2 for x64
Found 2 updates

Title                                                                                                Products   Classification   LastUpdated Size
-----                                                                                                --------   --------------   ----------- ----
2026-01 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5078127) (26100.7628) Windows 11 Updates 2026/01/24  4252.6 MB
2026-01 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5077744) (26100.7627) Windows 11 Updates 2026/01/17  4252.3 MB
```

### Example 2: Download an Update

```powershell
# Search and download in one pipeline
Get-MSCatalogUpdate -Search "KB5065426" | Save-MSCatalogUpdate -Destination "C:\Updates"
```

### Example 3: Filter by Date Range

```powershell
Get-MSCatalogUpdate -Search "Windows 11 24H2 x64" -FromDate "2025-06-01" -ToDate "2025-07-01"
```
---



### Example 4: Save an Update

```powershell
# Get update and download
$update = Get-MSCatalogUpdate -Search "Windows 11 24H2 x64" | Select-Object -First 1
Save-MSCatalogUpdate -Update $update -Destination "C:\Updates" -DownloadAll

# One-liner
Get-MSCatalogUpdate -Search "Windows 11 24H2 x64" | Select-Object -First 1 | Save-MSCatalogUpdate -Destination "C:\Updates" -DownloadAll
```

### Example 5: Export to JSON

```powershell
# Export to JSON (overwrite)
Get-MSCatalogUpdate -Search "Windows Server 2022 x64" -LastDays 30 -ExportJson "C:\Updates\Updates.json"

# Export to JSON (append)
Get-MSCatalogUpdate -Search "Windows Server 2022 x64" -ExportJson "C:\Updates\Updates.json" -Append

When -Append is used, existing entries are preserved and duplicate updates are automatically skipped
Output: Appended 2 updates to JSON file: updates.json (skipped 23 duplicates)

```

---

### Example 6: Retrieve Supersedence Relationships

```powershell
Get-MSCatalogUpdate `
    -Search "Windows Server 24H2" `
    -IncludeSupersedence

# Inspect relationships explicitly (the default output remains the normal table)
$updates = Get-MSCatalogUpdate -Search "KB5043080" -IncludeSupersedence
$updates | Select-Object Guid, Supersedes, SupersededBy, SupersedenceStatus
$updates[0].SupersededBy | Format-Table Guid, Title
```

`-IncludeSupersedence` without exclusion fetches detail pages for all unique update
GUIDs remaining after filtering, with up to four concurrent requests and a
20-second timeout per request. `-ExcludeSuperseded` uses the lazy strategy described
below, including when both switches are supplied.
Successful results (including title-only relationships) are cached for five minutes
in the module session, up to 256 updates; failed lookups are retried on the next
command invocation. Reimporting the module with `-Force` clears this cache.
Without either switch, no supersedence requests are made, the relationship
properties remain `$null`, and `SupersedenceStatus` is `NotRequested`.

The default output always uses the normal table (`Title`, `Products`,
`Classification`, `LastUpdated`, `Size`), including with `-IncludeSupersedence`
or `-ExcludeSuperseded`. Related patches and lookup metadata are available on the
objects and in exports; use `Select-Object` or `Format-List` to inspect them
explicitly. `-IncludeSuperseded` is also accepted as an alias for
`-IncludeSupersedence`.

| Property | Structure / meaning |
|----------|---------------------|
| `Supersedes` | Array of updates replaced by this update, or `$null` if none exist. Each entry has `Guid` (Catalog update GUID, or `$null` when unavailable) and `Title` (decoded Catalog title, which may contain a KB number). |
| `SupersededBy` | Array of updates that replace this update, with the same entry structure; `$null` if none exist. |
| `SupersedenceStatus` | `Retrieved`: both lists were parsed and all entries have GUIDs. `Partial`: both lists were parsed, but some entries have only a title. `Failed`: the request or metadata validation failed. `NotRequested`: no lookup was requested. |
| `SupersedenceError` | Explanation for `Partial` or `Failed`; otherwise empty. |

A confirmed `n/a` list becomes `$null`; `SupersedenceStatus` still identifies a
successful lookup (`Retrieved` or `Partial`). If either list is missing or
malformed, both relationship properties remain `$null`, status is `Failed`, and a
warning is emitted. A failed lookup must not be interpreted as having no relationships.
Title-only entries are retained with a null GUID. During exclusion, a title may
identify a unique eligible candidate locally, without modifying the original
metadata or its `Partial` status. KB-only or fuzzy matches are never used.
Use JSON (`-Format JSON` or `-ExportJson`) to preserve
the nested entries; CSV does not preserve nested relationship objects.

This feature reads the public detail page's **Package Details** HTML, including
`supersedesInfo` and `supersededbyInfo`, rather than a documented supersedence API.
The markup and availability can change. For example, the
[server KB5044284 detail page](https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=a62b9737-1fe8-4df1-94b4-8ec61855a8d0)
can list an older update as plain title text without a GUID link. `Retrieved`
describes successful parsing of what the Catalog reports, not a guarantee that
Microsoft publishes a complete relationship graph. The data reflects the Catalog
at query time, not a historical snapshot. Only the relationships displayed for each
result are returned; related pages are not followed, no transitive closure is
computed. `-IncludeSupersedence` alone does not remove search results.

### Example 7: Exclude Updates Replaced Within the Selected Results

```powershell
Get-MSCatalogUpdate `
    -Search "Server 24H2" `
    -Architecture x64 `
    -Date "2026-09" `
    -AllPages `
    -ExcludeSuperseded

# Single date bounds and relative dates work as well
Get-MSCatalogUpdate -Search "Server 24H2" -ToDate "2026-09-30" -AllPages -ExcludeSuperseded
Get-MSCatalogUpdate -Search "Server 24H2" -FromDate "2026-09-01" -AllPages -ExcludeSuperseded
Get-MSCatalogUpdate -Search "Server 24H2" -LastDays 30 -AllPages -ExcludeSuperseded

# Alternatively, use a range of Catalog LastUpdated dates (both bounds inclusive)
Get-MSCatalogUpdate `
    -Search "Server 24H2" `
    -Architecture x64 `
    -FromDate "2026-09-01" `
    -ToDate "2026-09-30" `
    -AllPages `
    -ExcludeSuperseded
```

`-ExcludeSuperseded` works with every existing date filter: `-Date`, a date token
in `-Search`, `-FromDate` and `-ToDate` (separately or together), and `-LastDays`.
It also works without a date filter and includes supersedence metadata automatically.
All existing search filters, including `-TitleContains`, are applied before
comparing relationships.
Without an explicit date filter, candidates from every month remain eligible;
there is no automatic restriction to the newest month. Supersedence exclusion
removes historical candidates only when confirmed relationships justify it.
`-Date` and date tokens in `-Search` match title text (for example `2026-09`);
they are not interpreted as publication dates. `-FromDate`, `-ToDate`, and
`-LastDays` use `LastUpdated`. Date ranges may span multiple months. Both bounds are inclusive, so use
`-ToDate "2026-09-30"` for the end of September (`2026-10-01` includes October 1).
The filter then resolves active candidates sequentially by `LastUpdated`
descending, with GUID ascending as a deterministic tie-breaker. A newer date alone
does not establish supersedence. Both `Supersedes` and `SupersededBy` can prove a
replacement within the original eligible set. Confirmed replaced candidates are
eliminated immediately and their detail pages are not requested. For example,
when A replaces B, C and D and independent E replaces F, six candidates need only
two detail requests (A and E). If Microsoft reports replacements only in reverse
on the older updates, more lookups may still be necessary. Final `-SortBy` and
`-Descending` output options remain independent of this processing order.

For example, if September update
A is replaced by September update B, A is omitted and B is kept. When only
September is selected, an October replacement does not exclude a September result. Independent updates, such as
Windows and .NET updates, are evaluated separately using their relationships.

GUIDs are the primary relationship identity. Without a GUID, a relationship title
can identify a candidate only if its entire normalized title uniquely matches
one eligible GUID. Normalization only decodes HTML entities, collapses whitespace
and ignores case. Duplicate rows with the same GUID share one identity; different
GUIDs with the same title remain ambiguous even if one was already eliminated.
An explicit external GUID is never overridden by a local title match. Substrings,
KB numbers, version aliases and fuzzy matches do not establish identity.

All other search filters still apply. A replacement excluded by those filters
(for example a preview without `-IncludePreview`) is not used to remove a result.
Use `-AllPages` to consider all available result pages. Failed lookups and
unresolved or ambiguous relationships do not prove that an update is replaced; check
`SupersedenceStatus` and `SupersedenceError` for incomplete metadata. The relationship
properties retain the full current Catalog metadata, including other months.
`LastUpdated` can change later. If several date filters are specified, their
intersection is used. With only `-FromDate`, newer replacements can be included;
use `-ToDate` as well when an upper cutoff is needed. This
is filtering within the selected results, not reconstruction of a historical
Catalog snapshot or resolution of a complete servicing baseline.

Every retained candidate is evaluated and carries its lookup status and metadata,
including when `-IncludeSupersedence` is explicitly combined with exclusion.
Skipped candidates are removed from the results; the optimization does not return
unevaluated results as though their metadata were complete. Successful cache entries
are reused under the existing five-minute policy, duplicate GUIDs are resolved
once, and failed lookups remain eligible for retry on the next invocation.
`-Verbose` reports initial and remaining counts, metadata lookups, supplied metadata
reuse, individual cache hits, eliminations and total resolution duration. No extra
Catalog searches, patch-month selection or requests for external relationships
are performed. Published relationship arrays are not expanded transitively;
confirmed in-set replacement chains are used only to retain a valid replacement.

## 📚 Available Functions

| Function | Description |
|----------|-------------|
| `Get-MSCatalogUpdate` | Search and filter updates from Microsoft Update Catalog |
| `Save-MSCatalogUpdate` | Download update files to a specified location |
| `Save-MSCatalogOutput` | Export update information to Excel format |

---

## 🔍 Common Use Cases

### Windows 10/11 Patch Management
```powershell
# Get latest Windows 11 security updates
Get-MSCatalogUpdate -Search "Windows 11 24h2 x64" -UpdateType "Security Updates" -LastDays 30
```

### WSUS/SCCM Offline Updates
```powershell
# Download updates for offline deployment
Get-MSCatalogUpdate -Search "KB5043178" -Architecture x64 | Save-MSCatalogUpdate -Destination "\\server\updates" -DownloadAll
```

### Server Patching Automation
```powershell
# Get Windows Server 2022 updates from last 90 days
Get-MSCatalogUpdate -Search "Windows Server 2022" -LastDays 90
```

### Filter by Size for Bandwidth Management
```powershell
# Find updates smaller than 500MB
Get-MSCatalogUpdate -Search "Windows 10 1809" -MaxSize 500 -SizeUnit MB
```

---

## 📖 Full Documentation

For detailed documentation, advanced examples, and parameter reference, visit:

👉 **[MSCatalogLTS Wiki](https://github.com/Marco-online/MSCatalogLTS/wiki/MSCatalogLTS)**

👉 **[GitHub Pages Documentation](https://marco-online.github.io/MSCatalogLTS)** *(coming soon)*

---

## 🛠️ Requirements

- **PowerShell**: 5.1 or higher (including PowerShell 7+)
- **Operating System**: Windows 10/11, Windows Server 2016+, or any OS with PowerShell Core
- **Internet Connection**: Required to query Microsoft Update Catalog
- **Optional**: ImportExcel module (for `Save-MSCatalogOutput` function)

---

## 🤝 Contributing

Contributions are welcome! Please feel free to submit:

- 🐛 Bug reports via [Issues](https://github.com/Marco-online/MSCatalogLTS/issues)
- 💡 Feature requests
- 🔧 Pull requests

---

## 📝 License

This project is licensed under the [MIT License](LICENSE).

---

## 🌟 Credits

MSCatalogLTS is inspired by and builds upon [MSCatalog](https://github.com/ryan-jan/MSCatalog) by ryan-jan. Thank you for the original groundwork!

---

## 🏷️ Keywords

`powershell` `windows-update` `microsoft-update-catalog` `patch-management` `wsus` `sccm` `windows-10` `windows-11` `windows-server` `security-updates` `cumulative-updates` `offline-updates` `powershell-module` `system-administration` `it-automation` `update-management` `kb-updates` `msu-files` `cab-files` `enterprise-deployment`

---

## 📧 Support

- 📖 [Documentation](https://github.com/Marco-online/MSCatalogLTS/wiki)
- 💬 [Issues](https://github.com/Marco-online/MSCatalogLTS/issues)
- 🌟 [PowerShell Gallery](https://www.powershellgallery.com/packages/MSCatalogLTS)

---

<p align="center">
  <strong>⭐ If you find MSCatalogLTS useful, please consider giving it a star!</strong>
</p>

<p align="center">
  Made with ❤️ for the PowerShell community
</p>
