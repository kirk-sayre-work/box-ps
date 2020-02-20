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
    [switch] $Dockerize,
    [parameter(Position=0, Mandatory=$true)][String] $InFile,
    [parameter(Position=1, Mandatory=$true)][String] $OutFile
)

# arg validation
if (!(Test-Path $InFile)) {
    Write-Host "[-] input file does not exist. exiting."
    exit -1
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

# remove imported modules and clean up non-output file system artifacts
function CleanUp {

    param(
        [string] $WorkingDir
    )

    Remove-Module HarnessBuilder -ErrorAction SilentlyContinue
    Remove-Module ScriptInspector -ErrorAction SilentlyContinue
    Remove-Module Utils -ErrorAction SilentlyContinue
    Remove-Item -Recurse $WorkingDir
}

# don't run it here, pull down the box-ps docker container and run it in there
if ($Dockerize) {

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

    Write-Host "[+] running box-ps in container"

    $shortInName = GetShortFileName $InFile
    $shortOutName = GetShortFileName $OutFile

    # move file into container, run box-ps, move results file out
    docker cp $InFile "$containerId`:/opt/box-ps/"
    docker exec $containerId pwsh ./box-ps.ps1 -InFile $shortInName -OutFile $shortOutName
    docker cp "$containerId`:/opt/box-ps/$shortOutName" $OutFile

    Write-Host "[+] moved sandbox results from container to $OutFile"

    # clean up
    docker kill $containerId > $null
}
else {

    $workingDir = "./working"
    $stderrPath = "$workingDir/stderr.txt"
    $stdoutPath = "$workingDir/stdout.txt"
    $actionsPath = "$workingDir/actions.json"
    $harnessPath = "$workingDir/harness.ps1"
    $harnessedScriptPath = "$workingDir/harnessedscript.ps1"
    
    # create working directory to store 
    if (Test-Path $workingDir) {
        Remove-Item -Force $workingDir/*
    }
    else {
        mkdir $workingDir
    }
    
    Import-Module -Name ./HarnessBuilder.psm1
    Import-Module -Name ./ScriptInspector.psm1
    
    $script = (Get-Content $InFile -ErrorAction Stop | Out-String)
    
    # build the harness
    $harness = BuildHarness 
    $harness | Out-File $harnessPath
    
    # modify the script to integrate it with the harness
    $script = BoxifyScript $script
    
    # attach the harness to the script
    $harnessedScript = $harness + "`r`n`r`n" + $script
    $harnessedScript | Out-File -FilePath $harnessedScriptPath
    
    Write-Host "[+] sandboxing script"

    # run it
    (timeout 5 pwsh -noni $harnessedScriptPath 2> $stderrPath 1> $stdoutPath)
    
    # a lot of times actions.json will not be present if things go wrong
    if (!(Test-Path $actionsPath)) {
        Write-Host "[-] sandboxing failed with an internal error. please post an issue on GitHub with the failing powershell"
        CleanUp $workingDir
        Exit(-1)
    }

    # output the actions JSON
    $actionsJson = Get-Content -Raw $actionsPath 
    "[" + $actionsJson.TrimEnd(",`r`n") + "]" | Out-File $OutFile
    Write-Host "[+] box-ps wrote sandbox results to $OutFile"
    
    CleanUp $workingDir
}