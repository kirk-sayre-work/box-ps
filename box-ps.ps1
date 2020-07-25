<# known issues
    Overrides do not support wildcard arguments, so if the malicious powershell uses wildcards and the
    override goes ahead and executes the function because it's safe, it may error out (which is fine)

    liable to have AmbiguousParameterSet errors...
        - Get-Help doesn't say whether or not the param is required differently accross parameter sets,
            so if it's required in one but not the other, we may get this error
        -Maybe just on New-Object so far? There were weird discrepancies between the linux Get-Help 
        and the windows one
#>

param (
    [switch] $Docker,
    [parameter(ParameterSetName="ReportOnly", Mandatory=$true)]
    [switch] $ReportOnly,
    [parameter(Position=0, Mandatory=$true)]
    [String] $InFile,
    [parameter(ParameterSetName="ReportOnly", Mandatory=$true)]
    [parameter(ParameterSetName="IncludeArtifacts")]
    [parameter(Position=1)]
    [String] $OutFile,
    [parameter(ParameterSetName="IncludeArtifacts")]
    [string] $OutDir
)

# arg validation
if (!(Test-Path $InFile)) {
    Write-Host "[-] input file does not exist. exiting."
    exit -1
}

# give OutDir a default value if the user hasn't specified they don't want artifacts 
if (!$ReportOnly -and !$OutDir) {
    # by default named <script>.boxed in the current working directory
    $OutDir = "./$($InFile.Substring($InFile.LastIndexOf("/") + 1)).boxed"
}

class Report {

    [object[]] $Actions
    [object] $PotentialIndicators

    Report([object[]] $actions, [object] $potentialIndicators) {
        $this.Actions = $Actions
        $this.PotentialIndicators = $potentialIndicators
    }
}

# cuts the full path from the file path to leave just the name
function GetShortFileName {
    param(
        [string] $Path
    )

    if ($Path.Contains("/")) {
        $shortName = $Path.Substring($Path.LastIndexOf("/")+1)
    }
    else {
        $shortName = $Path
    }

    return $shortName
}


# removes, if present, the invocation to Powershell that comes up front. It may be written to
# be interpreted with a cmd.exe shell, having cmd.exe obfuscation, and therefore does not play well 
# with our PowerShell interpreted powershell.exe override. Also records the initial action as a 
# script execution of the code we come up with here (decoded if it was b64 encoded).
function GetInitialScript {

    param(
        [string] $OrigScript
    )

    # if the invocation uses an encoded command, we need to decode that
    # is encoded if there's an "-e" or "-en" and there's a base64 string in the invocation
    if ($OrigScript -match ".*\-[Ee][Nn]?.*") {

        $match = [Regex]::Match($OrigScript, ".*?([A-Za-z0-9+/=]{40,}).*").captures
        if ($match -ne $null) {
            $encoded = $match.groups[1]
            $is_encoded = $true
        }
    }

    $scrubbed = $OrigScript -replace "^[Pp][Oo][Ww][Ee][Rr][Ss][Hh][Ee][Ll][Ll](.exe)? ((-[\w``]+ ([\w``]+ )?)?)*"

    if ($is_encoded) {
        $decoded = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($encoded))
    }
    else {
        $decoded = $scrubbed
    }

    # record the script
    [hashtable] $action = @{
        "Behaviors" = @("script_exec")
        "Actor" = "powershell.exe"
        "BehaviorProps" = @{
            "script" = @($decoded)
        }
    }

    $json = $action | ConvertTo-Json -Depth 10
    ($json + ",") | Out-File -Append "$WORK_DIR/actions.json"

    return $decoded
}

# For some reason, some piece of the powershell codebase behind the scenes is calling my Test-Path
# override and that invocation is showing up in the actions. Haven't been able to track it down.
function StripBugActions {

    param(
        [object[]] $Actions
    )

    $actions = $Actions | ForEach-Object {
        if ($_.Actor -eq "Microsoft.PowerShell.Management\Test-Path") {
            if ($_.BehaviorProps.paths -ne @("env:__SuppressAnsiEscapeSequences")) {
                $_
            }
        }
        else {
            $_
        }
    }

    return $actions
}

function WranglePotentialIOCs {

    param(
        [object[]] $Actions
    )

    $pathsSet = New-Object System.Collections.Generic.HashSet[string]
    $urlsSet = New-Object System.Collections.Generic.HashSet[string]

    # gather all file paths
    $Actions | Where-Object -Property Behaviors -contains "file_system" | ForEach-Object {
        $($_.BehaviorProps.paths | ForEach-Object { $pathsSet.Add($_) > $null })
    }

    # gather all network urls
    $Actions | Where-Object -Property Behaviors -contains "network" | ForEach-Object {
        $($_.BehaviorProps.uri | ForEach-Object { $urlsSet.Add($_) > $null })
    }

    # ingest the scraped urls the script inspector gathered
    $scraped_urls = Get-Content $WORK_DIR/scraped_urls.txt -ErrorAction SilentlyContinue
    if ($scraped_urls) {
        $scraped_urls | ForEach-Object { $urlsSet.Add($_) > $null }
    }

    $paths = [string[]]::new($pathsSet.Count)
    $urls = [string[]]::new($urlsSet.Count)
    $urlsSet.CopyTo($urls)
    $pathsSet.CopyTo($paths)

    $potentialIndicators = @{
        "network" = $urls;
        "file_system" = $paths
    }

    return $potentialIndicators
}

# remove imported modules and clean up non-output file system artifacts
function CleanUp {

    Remove-Module HarnessBuilder -ErrorAction SilentlyContinue
    Remove-Module ScriptInspector -ErrorAction SilentlyContinue
    Remove-Module Utils -ErrorAction SilentlyContinue
    Remove-Item -Recurse $WORK_DIR
}

$WORK_DIR = "./working"

# don't run it here, pull down the box-ps docker container and run it in there
if ($Docker) {

    # test to see if docker is installed. EXIT IF NOT
    try {
        $output = docker ps 2>&1
    }
    catch [System.Management.Automation.CommandNotFoundException] {
        Write-Host "[-] docker is not installed. install it and add your user to the docker group"
        Exit(-1)
    }

    # some other error with docker. EXIT
    if ($output -and $output.GetType().Name -eq "ErrorRecord") {
        $msg = $output.Exception.Message
        if ($msg.Contains("Got permission denied")) {
            Write-Host "[-] permissions incorrect. add your user to the docker group"
            Exit(-1)
        }
        Write-Host "[-] there's a problem with your docker environment..."
        Write-Host $msg
    }

    Write-Host "[+] pulling latest docker image"
    docker pull connorshride/box-ps:latest > $null
    Write-Host "[+] starting docker container"
    docker run -td --network none connorshride/box-ps:latest > $null

    # get the ID of the container we just started
    $psOutput = docker ps -f status=running -f ancestor=connorshride/box-ps -l
    $idMatch = $psOutput | Select-String -Pattern "[\w]+_[\w]+"
    $containerId = $idMatch.Matches.Value

    # modify args for running in the container
    # just keep all the input/output files in the box-ps dir in the container
    $PSBoundParameters.Remove("Docker") > $null
    $PSBoundParameters["InFile"] = GetShortFileName $InFile

    if ($OutFile) {
        $PSBoundParameters["OutFile"] = "./out.json"
    }

    if ($OutDir) {
        $PSBoundParameters["OutDir"] = "./outdir"
    }

    Write-Host "[+] running box-ps in container"
    docker cp $InFile "$containerId`:/opt/box-ps/"
    docker exec $containerId pwsh /opt/box-ps/box-ps.ps1 @PSBoundParameters > $null

    if ($OutFile) {
        docker cp "$containerId`:/opt/box-ps/out.json" $OutFile
        Write-Host "[+] moved JSON report from container to $OutFile"
    }

    if ($OutDir) {

        if (Test-Path $OutDir) {
            Remove-Item -Recurse $OutDir
        }

        docker cp "$containerId`:/opt/box-ps/outdir" $OutDir
        Write-Host "[+] moved results from container to $OutDir"
    }

    # clean up
    docker kill $containerId > $null
}
# sandbox outside of container
else {

    $stderrPath = "$WORK_DIR/stderr.txt"
    $stdoutPath = "$WORK_DIR/stdout.txt"
    $actionsPath = "$WORK_DIR/actions.json"
    $harnessedScriptPath = "$WORK_DIR/harnessed_script.ps1"
    
    # create working directory to store 
    if (Test-Path $WORK_DIR) {
        Remove-Item -Force $WORK_DIR/*
    }
    else {
        New-Item $WORK_DIR -ItemType Directory > $null
    }
    
    Import-Module -Name $PSScriptRoot/HarnessBuilder.psm1
    Import-Module -Name $PSScriptRoot/ScriptInspector.psm1
    
    $script = (Get-Content $InFile -ErrorAction Stop | Out-String)
    $script = GetInitialScript $script

    # build harness and integrate script with it
    $harness = BuildHarness
    $script = PreProcessScript $script

    # attach the harness to the script
    $harnessedScript = $harness + "`r`n`r`n" + $script
    $harnessedScript | Out-File -FilePath $harnessedScriptPath
    
    Write-Host "[+] sandboxing script"

    # run it
    (timeout 5 pwsh -noni $harnessedScriptPath 2> $stderrPath 1> $stdoutPath)
    
    # a lot of times actions.json will not be present if things go wrong
    if (!(Test-Path $actionsPath)) {
        $message = "sandboxing failed with an internal error. please post an issue on GitHub with the failing powershell"
        Write-Error -Message $message -Category NotSpecified
        CleanUp
        Exit(-1)
    }

    # ingest the actions, potential IOCs, create report
    $actionsJson = Get-Content -Raw $actionsPath
    $actions = "[" + $actionsJson.TrimEnd(",`r`n") + "]" | ConvertFrom-Json
    $actions = $(StripBugActions $actions)
    $potentialIndicators = $(WranglePotentialIOCs $actions)
    $report = [Report]::new($actions, $potentialIndicators)
    $reportJson = $report | ConvertTo-Json -Depth 10

    # output the JSON report where the user wants it
    if ($OutFile) {
        $reportJson | Out-File $OutFile
        Write-Host "[+] wrote JSON report to $OutFile"
    }

    # user wants more detailed artifacts as well as the report
    if ($OutDir) {

        # overwrite output dir if it already exists
        if (Test-Path $OutDir) {
            Remove-Item $OutDir/*
        }
        else {
            New-Item $OutDir -ItemType Directory > $null
        }

        # move some stuff from working directory here
        Move-Item $WORK_DIR/stdout.txt $OutDir/
        Move-Item $WORK_DIR/stderr.txt $OutDir/
        Move-Item $WORK_DIR/layers.ps1 $OutDir/
        $reportJson | Out-File $OutDir/report.json

        Write-Host "[+] moved analysis results to $OutDir"
    }

    CleanUp
}