<#
.SYNOPSIS
  Converts GTA3/Vice City GXT files to a text file and back

.PARAMETER inPath
  Path to the input file (gxt or txt)

.PARAMETER outPath
  Path to the output file (gxt or txt)

.EXAMPLE
  PS> ./gxt-to-txt-converter.ps1 "D:/Program Files (x86)/GTA Vice City/TEXT/american.gxt" "D:/desktop/text.txt"
  Converts a GXT file to a text file

  PS> ./gxt-to-txt-converter.ps1 "D:/desktop/text.txt" "D:/Program Files (x86)/GTA Vice City/TEXT/american.gxt"
  Converts a text file to a GXT file
  It will also look for files named text.0.txt, text.1.txt, etc.

.NOTES
  Author: Ivan Lychkov
  License: CC0
#>

param(
  [string] $inPath,
  [string] $outPath
)

try {
  $inFile = Get-Item $inPath
  $tables = @{}
  if ($inFile.Extension -eq ".gxt") {
    Write-Host "Reading GXT file"
    $gxtBytes = [io.file]::ReadAllBytes($inFile)
    $tkeysBlockSize = [bitconverter]::ToInt32($gxtBytes[4..7], 0)
    $tableCount = $tkeysBlockSize / 12
    Write-Host "Expected $tableCount tables"
    for ($tableIndex = 0; $tableIndex -lt $tableCount; $tableIndex++) {
      $tkeyStart = 8 + $tableIndex * 12
      $name = [text.encoding]::ASCII.GetString($gxtBytes[$tkeyStart..($tkeyStart + 7)]).Trim(" `0")
      $offset = [bitconverter]::ToInt32($gxtBytes[($tkeyStart + 8)..($tkeyStart + 11)], 0)
      
      if ($tableIndex -ne 0) {
        $offset += 8
      }
      $offset += 4
      
      $tkeyBlockSize = [bitconverter]::ToInt32($gxtBytes[($offset)..($offset + 3)], 0)
      $stringCount = $tkeyBlockSize / 12
      $strings = @{}
      
      for ($stringIndex = 0; $stringIndex -lt $stringCount; $stringIndex++) {
        $stringStart = $offset + 4 + $stringIndex * 12
        $stringOffset = [bitconverter]::ToInt32($gxtBytes[($stringStart)..($stringStart + 3)], 0)
        $stringOffset += $offset + 12 + $tkeyBlockSize
        $stringName = [text.encoding]::ASCII.GetString($gxtBytes[($stringStart + 4)..($stringStart + 10)]).Trim(" `0")
        $stringValueBytes = @()
        do {
          $charByte1 = $gxtBytes[$stringOffset++]
          $charByte2 = $gxtBytes[$stringOffset++]
          if ($charByte2 -ne 0) {
            Write-Error "Unexpected non-zero byte. Table: $name; string: $stringName"
            exit 1
          }
          if ($charByte1 -ne 0) {
            $stringValueBytes += $charByte1
          }
        } while ($charByte1 -ne 0)
        $stringValue = [text.encoding]::ASCII.GetString($stringValueBytes)
        $strings[$stringName] = $stringValue
      }
      
      $tables[$name] = @{ strings = $strings }
    }
  } elseif ($inFile.Extension -eq ".txt") {
    Write-Host "Reading text file"
    $lines = [System.Collections.ArrayList]@()
    $fileLines = [io.file]::ReadAllLines($inFile)
    $lines.AddRange($fileLines)
    
    $extraFileIndex = 0
    $path1 = $inPath.Substring(0, $inPath.length - 4)
    do {
      $extraFilePath = $path1 + ".$extraFileIndex.txt"
      try {
        $inFile = Get-Item $extraFilePath -ErrorAction Stop
        $extraLines = [io.file]::ReadAllLines($inFile)
        Write-Host "Found extra text file $extraFilePath"
        $lines.AddRange($extraLines)
      } catch {
        break
      }
      $extraFileIndex++
    } while ($true)
    
    foreach ($line in $lines) {
      if ($line[0] -eq "[" -and $line[-1] -eq "]") {
        $name = $line.trim("[]")
        if (!$tables.ContainsKey($name)) {
          $tables[$name] = @{ strings = @{} }
        }
        $currentTable = $tables[$name]
        continue
      }
      if ($line.Trim() -eq "") {
        continue
      }
      $delimiterIndex = $line.IndexOf("=")
      if ($delimiterIndex -eq -1) {
        Write-Error "Cannot parse line $line"
        exit 1
      }
      $stringName = $line.Substring(0, $delimiterIndex).TrimEnd()
      $stringValue = $line.Substring($delimiterIndex + 1).TrimStart()
      $currentTable.strings[$stringName] = $stringValue
    }
  } else {
    Write-Error "Unrecognized format: $($inFile.Extension)"
    exit 1
  }
  
  $tableNames = $tables.Keys
  if (!$tableNames.Contains("MAIN")) {
    Write-Error "MAIN table not found"
    exit 1
  }
  $tableNamesSorted = ,"MAIN" + ($tableNames | where { $_ -ne "MAIN" } | sort)
  
  $outFileExt = [io.path]::GetExtension($outPath)
  if ($outFileExt -eq ".gxt") {
    Write-Host "Writing GXT file"
    $tkeysBlockSize = $tableNamesSorted.Length * 12
    $outBytes = [System.Collections.ArrayList]@()
    $outBytes.AddRange([text.encoding]::ASCII.GetBytes("TABL"))
    $outBytes.AddRange([bitconverter]::GetBytes([int32]$tkeysBlockSize))
    
    $tableContentBytes = [System.Collections.ArrayList]@()
    $tableIndex = 0
    foreach ($tableName in $tableNamesSorted) {
      $table = $tables[$tableName]
      $table.offset = $tableContentBytes.Count + $tkeysBlockSize + 8
      $stringNamesSorted = [System.Collections.ArrayList]$table.strings.Keys
      $stringNamesSorted.Sort([System.StringComparer]::OrdinalIgnoreCase)

      if ($tableName -ne "MAIN") {
        $bytes = [text.encoding]::ASCII.GetBytes($tableName)
        while ($bytes.Length -lt 8) {
          $bytes += 0x00
        }
        $tableContentBytes.AddRange($bytes)
      }      $tableContentBytes.AddRange([text.encoding]::ASCII.GetBytes("TKEY"))
      
      $tkeyBlockSize = $stringNamesSorted.Count * 12
      $tableContentBytes.AddRange([bitconverter]::GetBytes([int32]$tkeyBlockSize))
      
      $offset = 0
      foreach ($stringName in $stringNamesSorted) {
        $tableContentBytes.AddRange([bitconverter]::GetBytes([int32]$offset))
        $stringSize = ($table.strings[$stringName].Length + 1) * 2
        $offset += $stringSize
    
        $bytes = [text.encoding]::ASCII.GetBytes($stringName)
        while ($bytes.Length -lt 8) {
          $bytes += 0x00
        }
        $tableContentBytes.AddRange($bytes)
      }
      
      $tableContentBytes.AddRange([text.encoding]::ASCII.GetBytes("TDAT"))
      $size = [math]::ceiling($offset / 4) * 4
      $tableContentBytes.AddRange([bitconverter]::GetBytes([int32]$size))
      
      foreach ($stringName in $stringNamesSorted) {
        $charBytes = [text.encoding]::ASCII.GetBytes($table.strings[$stringName])
        foreach ($byte in $charBytes) {
          $null = $tableContentBytes.Add($byte)
          $null = $tableContentBytes.Add(0x00);
        }
        $null = $tableContentBytes.Add(0x00);
        $null = $tableContentBytes.Add(0x00);
      }
      
      $lengthModulus = $tableContentBytes.Count % 4
      for ($i = 0; $i -lt $lengthModulus; $i++) {
        $null = $tableContentBytes.Add(0x00)
      }
      
      $tableIndex++
    }
    
    $tableNameBytes = [System.Collections.ArrayList]@()
    foreach ($tableName in $tableNamesSorted) {
      $table = $tables[$tableName]
      if ($tableName.Length -gt 7) {
        Write-Error "Table name too long: $tableName"
        exit 1
      }
      $bytes = [text.encoding]::ASCII.GetBytes($tableName)
      while ($bytes.Length -lt 8) {
        $bytes += 0x00
      }
      $tableNameBytes.AddRange($bytes)
      $tableNameBytes.AddRange([bitconverter]::GetBytes($table.offset))
    }
    
    $outBytes.AddRange($tableNameBytes)
    $outBytes.AddRange($tableContentBytes)
    
    [io.file]::WriteAllBytes($outPath, $outBytes)
  } elseif ($outFileExt -eq ".txt") {
    Write-Host "Writing text file"
    $outStr = [System.Text.StringBuilder]::new()
    foreach ($tableName in $tableNamesSorted) {
      $null = $outStr.AppendLine("[$tableName]")
      $table = $tables[$tableName]
      $stringNamesSorted = [System.Collections.ArrayList]$table.strings.Keys
      $stringNamesSorted.Sort([System.StringComparer]::OrdinalIgnoreCase)
      foreach ($stringName in $stringNamesSorted) {
        $stringValue = $table.strings[$stringName]
        while ($stringName.Length -lt 7) {
          $stringName += " "
        }
        $null = $outStr.AppendLine("$stringName = $stringValue")
      }
      $null = $outStr.AppendLine()
    }
    Out-File -FilePath $outPath -Encoding ASCII -InputObject $outStr.ToString()
  } else {
    Write-Error "Unrecognized format: $outFileExt"
    exit 1
  }
} catch {
  Write-Error "Error on line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
  exit 1
}
