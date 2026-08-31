# Run a SQL query against the Chinook practice database.
#
#   .\q.ps1 "SELECT TOP 5 * FROM Artist"      # inline query
#   .\q.ps1 -File exercises\01.sql             # run a .sql file
#   .\q.ps1                                    # no args -> list tables

param(
    [Parameter(Position = 0)] [string] $Query,
    [string] $File
)

$server = ".\SQLEXPRESS"
$db     = "Chinook"

# -W trims trailing spaces, -s sets the column separator, -w widens the line buffer
$fmt = @('-W', '-s', '|', '-w', '4000')

if ($File) {
    sqlcmd -S $server -E -C -d $db @fmt -i $File
}
elseif ($Query) {
    sqlcmd -S $server -E -C -d $db @fmt -Q $Query
}
else {
    sqlcmd -S $server -E -C -d $db @fmt -Q "SELECT name AS Tables FROM sys.tables ORDER BY name;"
}
