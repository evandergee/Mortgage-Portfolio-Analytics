<#
    run_analysis.ps1 -- build the mortgage portfolio and run the full analysis.

      1. generate the synthetic loan book + performance history   (sql\00)
      2. build the amortization proc                              (sql\01)
      3. build the analytics layer (views + roll-rate proc)       (sql\02)
      4. validate the data                                        (sql\03)
      5. guided tour                                              (sql\04)

    Needs SQL Server with the Chinook database (the mtg schema is created there)
    and sqlcmd. Step 1 takes ~1 minute; the rest are seconds.
    Run:  .\run_analysis.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
function Sql($rel) { & "$root\q.ps1" -File (Join-Path $root $rel) | Write-Host }
function Head($n)  { Write-Host "`n### $n" -ForegroundColor Cyan }

Head '1. generate synthetic portfolio (~1 min)'; Sql 'sql\00_generate_portfolio.sql'
Head '2. amortization schedule proc';             Sql 'sql\01_amortization.sql'
Head '3. analytics layer';                        Sql 'sql\02_analytics_layer.sql'
Head '4. data-quality validation';                Sql 'sql\03_validate.sql'
Head '5. guided tour';                            Sql 'sql\04_demo.sql'

Write-Host "`nDone. Every check in step 4 should read PASS." -ForegroundColor Green
