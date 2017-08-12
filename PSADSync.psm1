Add-Type -AssemblyName 'System.DirectoryServices.AccountManagement'

$PSAdSyncConfiguration = Import-PowerShellDataFile -Path "$PSScriptRoot\Configuration.psd1"

function ConvertToSchemaAttributeType
{
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$AttributeName,

		[Parameter(Mandatory)]
		[AllowEmptyString()]
		[AllowNull()]
		$AttributeValue,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[ValidateSet('Read','Set')]
		[string]$Action
	)

	if ($AttributeValue) {
		switch ($AttributeName)
		{
			'accountExpires' {
				if ((-not $AttributeValue) -or ($AttributeValue -eq '9223372036854775807')) {
					0
				} else {
					if ([string]$AttributeValue -as [DateTime]) {
						$date = ([datetime]$AttributeValue).Date
					} else {
						$date = ([datetime]::FromFileTime($AttributeValue)).Date
					}
					switch ($Action) {
						'Read' {
							$date.AddDays(-1)
						}
						'Set' {
							$date.AddDays(2)
						}
						default {
							throw "Unrecognized input: [$_]"
						}
					}
				}
			}
			default {
				$AttributeValue
			}
		}
	} else {
		## If $AttributeValue is null, return an emptry string to prevent any references to the value from failing
		''
	}

}

function SetAdUser
{
	[OutputType([void])]
	[CmdletBinding(SupportsShouldProcess,ConfirmImpact = 'High')]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Identity,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[hashtable]$ActiveDirectoryAttributes
	)	

	$replaceHt = @{}
	foreach ($attrib in $ActiveDirectoryAttributes.GetEnumerator()) {
		$attribName = $attrib.Key
		$convertParams = @{
			AttributeName = $attrib.Key
			AttributeValue = $attrib.Value
			Action = 'Set'
		}
		$replaceHt.$attribName = (ConvertToSchemaAttributeType @convertParams)
	}

	$setParams = @{
		Identity = $Identity
		Replace = $replaceHt
	}
		
	if ($PSCmdlet.ShouldProcess("User: [$($Identity)] AD attribs: [$($replaceHt.Keys -join ',')] to [$($ActiveDirectoryAttributes.Values -join ',')]",'Set AD attributes')) {
		Write-Verbose -Message "Replacing AD attribs: [$($setParams.Replace | Out-String)]"
		Set-AdUser @setParams
	} 
}

function Get-CompanyAdUser
{
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[hashtable]$FieldMatchMap,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[hashtable]$FieldSyncMap
	)
	begin
	{
		$ErrorActionPreference = 'Stop'
	}
	process
	{
		try
		{
			$userSyncProperties = [array]($FieldSyncMap.Values)
			@($FieldMatchMap.GetEnumerator()).foreach({
				if ($_.Value -is 'scriptblock') {
					$userSyncProperties += ParseScriptBlockHeaders -FieldScriptBlock $_.Value | Select-Object -Unique
				} else {
					$userSyncProperties += $_.Value
				}
			})

			$userIdProperties = [array]($FieldMatchMap.Values)

			@(Get-AdUser -Filter '*' -Properties '*').where({
				$adUser = $_
				## Ensure at least one ID field is populated
				@($userIdProperties).where({ $adUser.($_) })
			})
		}
		catch
		{
			Write-Error -Message "Function: $($MyInvocation.MyCommand.Name) Error: $($_.Exception.Message)"
		}
	}
}

function NewUserName
{
	[OutputType('string')]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[pscustomobject]$CsvUser,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Pattern,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[hashtable]$FieldMap
	)

	if (-not (TestFieldMapIsValid -UserMatchMap $FieldMap)) {
		throw 'One or more values in FieldMap parameter are missing.'
	}

	switch ($Pattern)
	{
		'FirstInitialLastName' {
			'{0}{1}' -f ($CsvUser.($FieldMap.FirstName)).SubString(0, 1), $CsvUser.($FieldMap.LastName)
		}
		'FirstNameLastName' {
			'{0}{1}' -f $CsvUser.($FieldMap.FirstName), $CsvUser.($FieldMap.LastName)
		}
		'FirstNameDotLastName' {
			'{0}.{1}' -f $CsvUser.($FieldMap.FirstName), $CsvUser.($FieldMap.LastName)
		}
		default {
			throw "Unrecognized UserNamePattern: [$_]"
		}
	}
}

function GetCsvColumnHeaders
{
	[OutputType([string])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$CsvFilePath
	)
	
	(Get-Content -Path $CsvFilePath | Select-Object -First 1).Split(',') -replace '"'
}

# .ExternalHelp PSADSync-Help.xml
function Get-AvailableAdUserAttribute {
	param()

	$schema =[DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema()
	$userClass = $schema.FindClass('user')
	
	foreach ($name in $userClass.GetAllProperties().Name | Sort-Object) {
		
		$output = [ordered]@{
			ValidName = $name
			CommonName = $null
		}
		switch ($name)
		{
			'sn' {
				$output.CommonName = 'SurName'
			}
		}
		
		[pscustomobject]$output
	}
}

function TestIsValidAdAttribute {
	[OutputType([bool])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Name
	)

	if ($Name -in (Get-AvailableAdUserAttribute).ValidName) {
		$true
	} else {
		$false
	}
}

function TestCsvHeaderExists
{
	[OutputType([bool])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$CsvFilePath,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[object[]]$Header
	)

	$csvHeaders = GetCsvColumnHeaders -CsvFilePath $CsvFilePath

	## Parse out the CSV headers used if the field is a scriptblock
	$commonHeaders = @($Header).foreach({
		$_ | ForEach-Object {
			if ($_ -is 'scriptblock') {
				ParseScriptBlockHeaders -FieldScriptBlock $_
			} else {
				$_
			}
		}
	})
	$commonHeaders = $commonHeaders | Select-Object -Unique

	$matchedHeaders = $csvHeaders | Where-Object { $_ -in $commonHeaders }
	if (@($matchedHeaders).Count -ne @($commonHeaders).Count) {
		$false
	} else {
		$true
	}
}

function ParseScriptBlockHeaders
{
	[OutputType('$')]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[scriptblock[]]$FieldScriptBlock
	)
	
	$headers = @($FieldScriptBlock).foreach({
		$ast = [System.Management.Automation.Language.Parser]::ParseInput($_.ToString(),[ref]$null,[ref]$null)
		$ast.FindAll({$args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst]},$true).Value
	})
	$headers | Select-Object -Unique
	
}

function Get-CompanyCsvUser
{
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[ValidateScript({Test-Path -Path $_ -PathType Leaf})]
		[string]$CsvFilePath,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[hashtable]$Exclude
	)
	begin
	{
		$ErrorActionPreference = 'Stop'
		Write-Verbose -Message "Enumerating all users in CSV file [$($CsvFilePath)]"
	}
	process
	{
		try
		{
			$whereFilter = { '*' }
			if ($PSBoundParameters.ContainsKey('Exclude'))
			{
				$conditions = $Exclude.GetEnumerator() | ForEach-Object { "(`$_.'$($_.Key)' -ne '$($_.Value)')" }
				$whereFilter = [scriptblock]::Create($conditions -join ' -and ')
			}

			Import-Csv -Path $CsvFilePath | Where-Object -FilterScript $whereFilter
		}
		catch
		{
			Write-Error -Message "Function: $($MyInvocation.MyCommand.Name) Error: $($_.Exception.Message)"
		}
	}
}

function New-CompanyAdUser
{
    [OutputType([void])]
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact = 'High')]
    param
    (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [pscustomobject]$CsvUser,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[ValidateSet('FirstInitialLastName','FirstNameLastName','FirstNameDotLastName')]
		[string]$UsernamePattern,
		
		[Parameter(Mandatory,ParameterSetName = 'Password')]
		[ValidateNotNullOrEmpty()]
		[securestring]$Password,

		[Parameter(Mandatory,ParameterSetName = 'RandomPassword')]
		[ValidateNotNullOrEmpty()]
		[switch]$RandomPassword,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[hashtable]$FieldSyncMap,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[hashtable]$FieldMatchMap,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[hashtable]$UserMatchMap
    )
	
	$userName = NewUserName -CsvUser $CsvUser -Pattern $UsernamePattern -FieldMap $UserMatchMap
	$newAdUserParams = @{ 
		Name = $userName 
		PassThru = $true
		GivenName = $CsvUser.($UserMatchMap.FirstName)
		Surname = $CsvUser.($UserMatchMap.LastName)
	}

	if ($RandomPassword.IsPresent) {
		$pw = NewRandomPassword
	} else {
		$Password = $pw
	}

	$otherAttribs = @{}
	$FieldSyncMap.GetEnumerator().foreach({
		$adAttribName = $_.Value
		$adAttribValue = $CsvUser.($_.Key)
		$otherAttribs.$adAttribName = $adAttribValue
	})
	$FieldMatchMap.GetEnumerator().foreach({
		$adAttribName = $_.Value
		$adAttribValue = $CsvUser.($_.Key)
		$otherAttribs.$adAttribName = $adAttribValue
	})

	$newAdUserParams.OtherAttributes = $otherAttribs

    if ($PSCmdlet.ShouldProcess("User: [$($userName)] AD attribs: [$($newAdUserParams | Out-String)]",'New AD User')) {
		if (Get-AdUser -Filter "samAccountName -eq '$userName'") {
			throw "The user to be created [$($userName)] already exists."
		} else {
			if ($newUser = New-ADUser @newAdUserParams) {
				Set-ADAccountPassword -Identity $newUser.DistinguishedName -Reset -NewPassword $pw
			}
		}
		
	}
	
}

function TestFieldMapIsValid
{
	[OutputType([bool])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory,ParameterSetName = 'Sync')]
		[ValidateNotNullOrEmpty()]
		[hashtable]$FieldSyncMap,

		[Parameter(Mandatory,ParameterSetName = 'Match')]
		[ValidateNotNullOrEmpty()]
		[hashtable]$FieldMatchMap,

		[Parameter(Mandatory,ParameterSetName = 'Value')]
		[ValidateNotNullOrEmpty()]
		[hashtable]$FieldValueMap,

		[Parameter(Mandatory,ParameterSetName = 'UserMatch')]
		[ValidateNotNullOrEmpty()]
		[hashtable]$UserMatchMap,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$CsvFilePath	
	)

	<#
		FieldSyncMap
		--------------
			Valid: 
				@{ <scriptblock>; <string> }
				@{ { if ($_.'NICK_NAME') { 'NICK_NAME' } else { 'FIRST_NAME' }} = 'givenName' }

				@{ <string>; <string> }

		FieldMatchMap
		--------------
			Valid: 
				@{ <scriptblock>; <string> }
				@{ <array>; <array> }
				@{ { if ($_.'csvIdField2') { $_.'csvIdField2' } else { $_.'csvIdField3'} } = 'adIdField2' }

				@{ <string>; <string> }

		FieldValueMap
		--------------
			Valid: 
				@{ <string>; <scriptblock> }
				@{ 'SUPERVISOR' = { $supId = $_.'SUPERVISOR_ID'; (Get-AdUser -Filter "EmployeeId -eq '$supId'").DistinguishedName }}
	#>

	if (-not $PSBoundParameters.ContainsKey('CsvFilePath') -and -not $UserMatchMap)
	{	
		throw 'CSVFilePath is required when testing any map other than UserMatchMap.'
	}

	$result = $true
	switch ($PSCmdlet.ParameterSetName)
	{
		'Sync' {
			$mapHt = $FieldSyncMap.Clone()
			if ($FieldSyncMap.GetEnumerator().where({ $_.Value -is 'scriptblock' })) {
				Write-Warning -Message 'Scriptblocks are not allowed as a value in FieldSyncMap.'
				$result = $false
			}
		}
		'Match' {
			$mapHt = $FieldMatchMap.Clone()
			if ($FieldMatchMap.GetEnumerator().where({ $_.Value -is 'scriptblock' })) {
				Write-Warning -Message 'Scriptblocks are not allowed as a value in FieldMatchMap.'
				$result = $false
			} elseif ($FieldMatchMap.GetEnumerator().where({ @($_.Key).Count -gt 1 -and @($_.Value).Count -eq 1 })) {
				$result = $false
			}
		}
		'Value' {
			$mapHt = $FieldValueMap.Clone()
			if ($FieldValueMap.GetEnumerator().where({ $_.Value -isnot 'scriptblock' })) {
				Write-Warning -Message 'A scriptblock must be a value in FieldValueMap.'
				$result = $false
			}
			
		}
		'UserMatch' {
			$mapHt = $UserMatchMap.Clone()
			if (($UserMatchMap.Keys | Where-Object { $_ -in @('FirstName','LastName') }).Count -ne 2) {
				$result = $false
			}
		}
		default {
			throw "Unrecognized input: [$_]"
		}
	}
	if ($result -and (-not $UserMatchMap)) {
	 	if (-not (TestCsvHeaderExists -CsvFilePath $CsvFilePath -Header ([array]($mapHt.Keys)))) {
			Write-Warning -Message 'CSV header check failed.'
			$false
		} else {
			$true
		}
	} else {
		$result
	}
	
}

function FindUserMatch
{
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[hashtable]$FieldMatchMap,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[object]$CsvUser,

		[Parameter()]
		[object[]]$AdUsers = $script:adUsers
	)
	$ErrorActionPreference = 'Stop'

	<# Possibilities
		$FieldMatchMap = @{ 
			@( { if ($_.'NICK_NAME') { 'NICK_NAME' } else { $_.'FIRST_NAME' }}, 'LAST_NAME' )
			@( 'givenName','surName' )
		}

		@($AdUsers).where({ $_.givenName -eq 'nick' -and $_.surName -eq 'last' })

		$FieldMatchMap = @{ 
			@( 'FIRST_NAME', 'LAST_NAME' )
			@( 'givenName', 'surName' )
		}

		@($AdUsers).where({ $_.givenName -eq 'first' -and $_.surName -eq 'last' })

		$CsvUser = [pscustomobject]@{
			NICK_NAME = 'nick'
			FIRST_NAME = 'first'
			LAST_NAME = 'last'
		}

	#>

	$whereFilterElements = @()

	[string[]]$fieldVals = $FieldMatchmap.Values | Select-Object
	$fieldKeys = @()

	$i = 0
	$FieldMatchMap.Keys.foreach({
		## @( { if ($_.'NICK_NAME') { 'NICK_NAME' } else { 'FIRST_NAME'} },'LAST_NAME')
	
		foreach ($k in $_) {
			if ($k -is 'scriptblock') {
				## { if ($_.'NICK_NAME') { 'NICK_NAME' } else { 'FIRST_NAME'} }

				## 'NICK_NAME'
				$csvProp = EvaluateCsvFieldCondition -Condition $k -CsvUser $CsvUser

			} else {
				$csvProp = $k
			}
			$fieldKeys += $csvProp

			## 'Joel'
			if ($value = $CsvUser.$csvProp) {
				$adProp = $fieldVals[$i]

				$whereFilterElements += '$_.{0} -eq "{1}"' -f $adProp,$value
			}
			$i++

		}
	})

	if (@($FieldMatchMap.Keys).Count -gt 1) {
		$whereFilter = [scriptblock]::Create($whereFilterElements -join ' -or ')
	} else {
		$whereFilter = [scriptblock]::Create($whereFilterElements -join ' -and ')
	}
	if ($adUserMatch = @($AdUsers).where($whereFilter)) {
		if (@($adUserMatch).Count -gt 1) {
			Write-Warning -Message 'More than one AD user found to match found. Skipping user...'
		} else {
			[pscustomobject]@{
				MatchedAdUser = $adUserMatch
				CSVAttemptedMatchIds = ($fieldKeys -join ',')
				ADAttemptedMatchIds = ($fieldVals -join ',')
			}
		}
		
	} else {
		Write-Verbose -Message 'No user match found for CSV user'
	}
}

function EvaluateCsvFieldCondition
{
	[OutputType('string')]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[scriptblock]$Condition,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[pscustomobject]$CsvUser
	)

	$csvFieldScript = $Condition.ToString() -replace '\$_','$CsvUser'
	& ([scriptblock]::Create($csvFieldScript))
	
}	

function FindAttributeMismatch
{
	[OutputType([hashtable])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		$AdUser,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[hashtable]$FieldSyncMap,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[pscustomobject]$CsvUser
	)

	$ErrorActionPreference = 'Stop'

	Write-Verbose -Message "Starting AD attribute mismatch check..."
	$FieldSyncMap.GetEnumerator().foreach({
		if ($_.Key -is 'scriptblock') {
			$csvFieldName = EvaluateCsvFieldCondition -Condition $_.Key -CsvUser $CsvUser
		} else {
			$csvFieldName = $_.Key
		}
		$adAttribName = $_.Value
		
		Write-Verbose -Message "Checking CSV field [$($csvFieldName)] / AD field [$($adAttribName)] for mismatches..."
		
		$adAttribValue = $AdUser.$adAttribName
		$csvAttribValue = $CsvUser.$csvFieldName
		if ($csvAttribValue) {
			$adConvertParams = @{
				AttributeName = $adAttribName
				AttributeValue = $adAttribValue
				Action = 'Read'
			}
			$adAttribValue = ConvertToSchemaAttributeType @adConvertParams
			Write-Verbose -Message "Comparing AD attribute value [$($adattribValue)] with CSV value [$($csvAttribValue)]..."
			
			## Compare the two property values and return the AD attribute name and value to be synced
			if ($adattribValue -ne $csvAttribValue) {
				@{
					ActiveDirectoryAttribute = @{ $adAttribName = $adattribValue }
					CSVField = @{ $csvFieldName = $csvAttribValue }
					ADShouldBe = @{ $adAttribName = $csvAttribValue }
				}
				Write-Verbose -Message "AD attribute mismatch found on AD attribute: [$($adAttribName)]."
			}
		}
	})
}

function NewRandomPassword
{
	[CmdletBinding()]
	[OutputType([System.Security.SecureString])]
	param
	(
		[Parameter()]
		[ValidateRange(8, 64)]
		[int]$Length = (Get-Random -Minimum 20 -Maximum 32),

		[Parameter()]
		[ValidateRange(0, 8)]
		[int]$Complexity = 3
	)
	$ErrorActionPreference = 'Stop'

	Add-Type -AssemblyName 'System.Web'

	# Generate a password with the specified length and complexity.
	Write-Verbose ('Generating password {0} characters in length and with a complexity of {1}.' -f $Length, $Complexity);
	$pw = [System.Web.Security.Membership]::GeneratePassword($Length, $Complexity)
	ConvertTo-SecureString -String $pw -AsPlainText -Force
	
}


function TestUserTerminated
{
	[OutputType([bool])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[object]$CsvUser
	)

	if (-not (TestIsUserTerminationEnabled)) {
		throw 'User termination checking is not enabled in the configuration'
	} else {
		$csvField = $PSAdSyncConfiguration.UserTerminationTest.CsvField
		$csvValue = $PSAdSyncConfiguration.UserTerminationTest.CsvValue
		
		if ($CsvUser.$csvField -eq $csvValue) {
			$true
		} else {
			$false
		}
	}
}

function TestIsUserTerminationEnabled
{
	[OutputType('bool')]
	[CmdletBinding()]
	param
	()

	if ($PSAdSyncConfiguration.UserTerminationTest.Enabled) {
		$true
	} else {
		$false
	}
}

function SyncCompanyUser
{
	[OutputType()]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Identity,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[pscustomobject]$CsvUser,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[hashtable[]]$ActiveDirectoryAttributes
	)

	$ErrorActionPreference = 'Stop'
	try {
		foreach ($ht in $ActiveDirectoryAttributes) {
			SetAdUser -Identity $Identity -ActiveDirectoryAttributes $ht
		}
		
	} catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}
}

function WriteLog
{
	[OutputType([void])]
	[CmdletBinding()]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$FilePath = '.\PSAdSync.csv',

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$CsvIdentifierField,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$CsvIdentifierValue,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[hashtable]$Attributes
	)
	
	$ErrorActionPreference = 'Stop'
	
	$time = Get-Date -Format 'g'
	$Attributes['CsvIdentifierValue'] = $CsvIdentifierValue
	$Attributes['CsvIdentifierField'] = $CsvIdentifierField
	$Attributes['Time'] = $time
	
	([pscustomobject]$Attributes) | Export-Csv -Path $FilePath -Append -NoTypeInformation

}

function GetCsvIdField
{
	[OutputType([bool])]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[object]$CsvUser,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[hashtable]$FieldMatchMap
	)


	$FieldMatchMap.Keys | ForEach-Object { 
		[pscustomobject]@{
			Field = $_
			Value = $CSVUser.$_
		}
	}
	
}

function GetManagerEmailAddress
{
	[OutputType('string')]
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[object]$AdUser
	)

	$ErrorActionPreference = 'Stop'

	if ($AdUser.Manager -and ($managerAdAccount = Get-ADUser -Filter "DistinguishedName -eq '$($AdUser.Manager)'" -Properties EmailAddress)) {
		$managerAdAccount.EmailAddress
	}	

}

function SendStaleAccountEmail
{
	[OutputType([void])]
	[CmdletBinding(SupportsShouldProcess,ConfirmImpact = 'High')]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[object]$AdUser,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$Subject = $PSAdSyncConfiguration.Email.Templates.UnusedAccount.Subject,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$FromEmailAddress = $PSAdSyncConfiguration.Email.Templates.UnusedAccount.FromEmailAddress,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$FromEmailName = $PSAdSyncConfiguration.Email.Templates.UnusedAccount.FromEmailName,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$SmtpServer = $PSAdSyncConfiguration.Email.SmtpServer

	)
	begin
	{
		$ErrorActionPreference = 'Stop'
	}
	process
	{
		try
		{
			if (-not $AdUser.Manager) {
				throw "No manager defined for user: [$($AdUser.name)]. Cannot send email."
			}
			if (-not ($managerEmail = GetManagerEmailAddress -AdUser $AdUser))
			{
				throw "Could not find a manager email address for user [$($AdUser.Name)]"
			}
			$emailBody = ReadEmailTemplate -Name UnusedSccount
			$emailBody = $emailBody -f $managerEmail,$AdUser.Name,$PSAdSyncConfiguration.CompanyName

			$sendParams = @{
				To = $managerEmail
				From = "$FromEmailName <$FromEmailAddress>"
				Subject = $Subject
				Body = $emailBody
				SmtpServer = $SmtpServer
			}
			if ($PSCmdlet.ShouldProcess($managerEmail,"Send email about account [$($AdUser.Name)]"))
			{
				Send-MailMessage @sendParams
			}
		}
		catch
		{
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}
}

function ReadEmailTemplate
{
	[OutputType('string')]
	[CmdletBinding(SupportsShouldProcess)]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Name	
	)
	
	if ($template = Get-ChildItem -Path "$PSScriptRoot\EmailTemplates" -Filter "$Name.txt") {
		Get-Content -Path $template.FullName -Raw
	}
}

function WriteProgressHelper {
	param (
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[int]$StepNumber,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$Message
	)
	Write-Progress -Activity 'Active Directory Report/Sync' -Status $Message -PercentComplete (($StepNumber / $script:totalSteps) * 100)
}

# .ExternalHelp PSADSync-Help.xml
function Invoke-AdSync
{
	[OutputType([void])]
	[CmdletBinding(SupportsShouldProcess,DefaultParameterSetName = 'Default')]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$CsvFilePath,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[hashtable]$FieldSyncMap,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[hashtable]$FieldMatchMap,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[hashtable]$FieldValueMap,

		[Parameter(Mandatory,ParameterSetName = 'CreateNewUsers')]
		[ValidateNotNullOrEmpty()]
		[switch]$CreateNewUsers,

		[Parameter(Mandatory,ParameterSetName = 'CreateNewUsers')]
		[ValidateNotNullOrEmpty()]
		[hashtable]$UserMatchMap,

		[Parameter(Mandatory,ParameterSetName = 'CreateNewUsers')]
		[ValidateNotNullOrEmpty()]
		[string]$UsernamePattern,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[switch]$ReportOnly,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[hashtable]$Exclude
	)
	begin
	{
		$ErrorActionPreference = 'Stop'
	}
	process
	{
		try
		{
			$getCsvParams = @{
				CsvFilePath = $CsvFilePath
			}

			if ($PSBoundParameters.ContainsKey('Exclude'))
			{
				if (-not (TestCsvHeaderExists -CsvFilePath $CsvFilePath -Header ([array]$Exclude.Keys))) {
					throw 'One or more CSV headers excluded with -Exclude do not exist in the CSV file.'
				}
				$getCsvParams.Exclude = $Exclude
			}

			if (-not (TestFieldMapIsValid -FieldSyncMap $FieldSyncMap -CsvFilePath $CsvFilePath)) {
				throw 'Invalid attribute found in FieldSyncMap.'
			}
			if (-not (TestFieldMapIsValid -FieldMatchMap $FieldMatchMap -CsvFilePath $CsvFilePath)) {
				throw 'Invalid attribute found in FieldMatchMap.'
			}

			if ($PSBoundParameters.ContainsKey('FieldValueMap'))
			{
				if (-not (TestFieldMapIsValid -FieldValueMap $FieldValueMap -CsvFilePath $CsvFilePath)) {
					throw 'Invalid attribute found in FieldValueMap.'
				}	
			}

			$FieldSyncMap.GetEnumerator().where({$_.Value -is 'string'}).foreach({
				if (-not (TestIsValidAdAttribute -Name $_.Value)) {
					throw 'One or more AD attributes in FieldSyncMap do not exist. Use Get-AvailableAdUserAttribute for a list of available attributes.'
				}
			})

			Write-Output 'Enumerating all Active Directory users. This may take a few minutes depending on the number of users...'
			if (-not ($script:adUsers = Get-CompanyAdUser -FieldMatchMap $FieldMatchMap -FieldSyncMap $FieldSyncMap)) {
				throw 'No AD users found'
			}
			Write-Output 'Active Directory user enumeration complete.'
			Write-Output 'Enumerating all CSV users...'
			if (-not ($csvusers = Get-CompanyCsvUser @getCsvParams)) {
				throw 'No CSV users found'
			}
			Write-Output 'CSV user enumeration complete.'

			$script:totalSteps = @($csvusers).Count
			$stepCounter = 0
			@($csvUsers).foreach({
				try {
					if ($ReportOnly.IsPresent) {
						$prgMsg = "Attempting to find attribute mismatch for user in CSV row [$($stepCounter + 1)]"
					} else {
						$prgMsg = "Attempting to find and sync AD any attribute mismatches for user in CSV row [$($stepCounter + 1)"
					}
					WriteProgressHelper -Message $prgMsg -StepNumber ($stepCounter++)
					$csvUser = $_
					if ($adUserMatch = FindUserMatch -CsvUser $csvUser -FieldMatchMap $FieldMatchMap) {
						Write-Verbose -Message 'Match'

						$CSVAttemptedMatchIds = $aduserMatch.CSVAttemptedMatchIds
						$csvIdValue = ($CSVAttemptedMatchIds | % {$csvUser.$_}) -join ','
						$csvIdField = $CSVAttemptedMatchIds -join ','

						#region FieldValueMap check
							$selectParams = @{ Property = '*' }
							if ($PSBoundParameters.ContainsKey('FieldValueMap')) {
								$selectParams.Property = @('*')
								$selectParams.Exclude = [array]($FieldValueMap.Keys)
								@($FieldValueMap.GetEnumerator()).foreach({
									$selectParams.Property += @{ 
										Name = $_.Key
										Expression = $_.Value
									}
								})
							}

							$csvUser = $csvUser | Select-Object @selectParams | foreach {
								if ($FieldValueMap -and (-not $_.($FieldValueMap.Keys))) {
									throw "The CSV [$($FieldValueMap.Keys)] field in FieldValueMap returned nothing for CSV user [$($csvIdValue)]."
								}
								$_
							}
						#endregion

						$findParams = @{
							AdUser = $adUserMatch.MatchedAdUser
							CsvUser = $csvUser
							FieldSyncMap = $FieldSyncMap
						}
						$attribMismatches = FindAttributeMismatch @findParams
						if ($attribMismatches) {
							$logAttribs = @{
								CSVAttributeName = ([array]($attribMismatches.CSVField.Keys))[0]
								CSVAttributeValue = ([array]($attribMismatches.CSVField.Values))[0]
								ADAttributeName = ([array]($attribMismatches.ActiveDirectoryAttribute.Keys))[0]
								ADAttributeValue = ([array]($attribMismatches.ActiveDirectoryAttribute.Values))[0]
								Message = $null
							}
							if (-not $ReportOnly.IsPresent) {
								$syncParams = @{
									CsvUser = $csvUser
									ActiveDirectoryAttributes = $attribMismatches.ADShouldBe
									Identity = $adUserMatch.MatchedAduser.samAccountName
								}
								Write-Verbose -Message "Running SyncCompanyUser with params: [$($syncParams | Out-String)]"
								SyncCompanyUser @syncParams
							}
						} elseif ($attribMismatches -eq $false) {
							throw 'Error occurred in FindAttributeMismatch'
						} else {
							Write-Verbose -Message "No attributes found to be mismatched between CSV and AD user account for user [$csvIdValue]"
							$logAttribs = @{
								CSVAttributeName = 'AlreadyInSync'
								CSVAttributeValue = 'AlreadyInSync'
								ADAttributeName = 'AlreadyInSync'
								ADAttributeValue = 'AlreadyInSync'
								Message = $null
							}
						}
					} else {
						## No user match was found
						if (-not ($csvIds = @(GetCsvIdField -CsvUser $csvUser -FieldMatchMap $FieldMatchMap).where({ $_.Field }))) {
							Write-Warning -Message  'No CSV ID fields were found.'
							$csvIdField = 'N/A'
							$csvIdValue = 'N/A'

							$logAttribs = @{
								CSVAttributeName = 'N/A'
								CSVAttributeValue = 'N/A'
								ADAttributeName = 'NoMatch'
								ADAttributeValue = 'NoMatch'
								Message = $null
							}
						} elseif ($CreateNewUsers.IsPresent) {
							$csvIdField = $csvIds.Field -join ','
							$newUserParams = @{
								CsvUser = $csvUser
								UsernamePattern = $UsernamePattern
								UserMatchMap = $UserMatchMap
								RandomPassword = $true
								FieldSyncMap = $FieldSyncMap
								FieldMatchMap = $FieldMatchMap
							}
							New-CompanyAdUser @newUserParams

							$logAttribs = @{
								CSVAttributeName = 'NewUserCreated'
								CSVAttributeValue = 'NewUserCreated'
								ADAttributeName = 'NewUserCreated'
								ADAttributeValue = 'NewUserCreated'
								Message = $null
							}
							$csvIdValue = ($csvIds | foreach { $csvUser.($_.Field) })
						} else {
							$csvIdField = $csvIds.Field -join ','
							$csvIdValue = 'N/A'

							$logAttribs = @{
								CSVAttributeName = 'N/A'
								CSVAttributeValue = 'N/A'
								ADAttributeName = 'NoMatch'
								ADAttributeValue = 'NoMatch'
								Message = $null
							}
						}
					}
					
				} catch {
					$logAttribs = @{
						CSVAttributeName = 'Error'
						CSVAttributeValue = 'Error'
						ADAttributeName = 'Error'
						ADAttributeValue = 'Error'
						Message = $_.Exception.Message
					}
				} finally {
					WriteLog -CsvIdentifierField $csvIdField -CsvIdentifierValue $csvIdValue -Attributes $logAttribs
				}
			})
		}
		catch
		{
			Write-Error -Message "Function: $($MyInvocation.MyCommand.Name) Error: $($_.Exception.Message)"
		}
	}
}