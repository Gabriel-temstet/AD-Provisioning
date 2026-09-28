<#
.SYNOPSIS
    Script de provisioning et de maintenance idempotente d'un annuaire Active Directory de laboratoire.

.DESCRIPTION
    Crée une structure d'OU complexes, des utilisateurs, des groupes de sécurité et des affectations
    à partir de fichiers CSV de configuration.
    Totalement idempotent et sécurisé pour les environnements de test.

.PARAMETER ConfigPath
    Chemin du dossier contenant les fichiers CSV (sites.csv, ous.csv, users.csv, groups.csv, memberships.csv).
    Valeur par défaut : ".\config"

.PARAMETER LogPath
    Chemin du dossier de sortie des fichiers de log.
    Valeur par défaut : ".\logs"

.PARAMETER WhatIf
    Mode simulation : valide la configuration et affiche toutes les opérations sans exécuter de modification AD.

.PARAMETER SkipGroups
    Ignore l'étape de création et de gestion des groupes/membres.

.EXAMPLE
    PS C:\> .\Invoke-ADProvisioning.ps1 -WhatIf
    Exécute une simulation complète avec contrôle de cohérence des CSV sans modifier Active Directory.

.EXAMPLE
    PS C:\> .\Invoke-ADProvisioning.ps1 -ConfigPath "C:\AD-Setup\config" -LogPath "C:\AD-Setup\logs"
    Exécute le provisioning complet Active Directory avec confirmation préalable.

.NOTES
    Auteur: Enterprise AD Admin
    Compatibilité: Windows PowerShell 5.1 & PowerShell 7.x
    Module requis: ActiveDirectory (RSAT)
#>

# ---------------------------------------------------------------------------
# Strict Mode & Paramètres
# ---------------------------------------------------------------------------
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

param(
    [string]$ConfigPath = ".\config",
    [string]$LogPath = ".\logs",
    [switch]$WhatIf,
    [switch]$SkipGroups
)

# ---------------------------------------------------------------------------
# Variables Globales de Session (Stats)
# ---------------------------------------------------------------------------
$script:LogFile = $null$script:StartTime = Get-Date

$script:Stats = @{
    OUsAnalyzed      = 0
    OUsCreated       = 0
    OUsExisted       = 0
    UsersAnalyzed    = 0
    UsersCreated     = 0
    UsersExisted     = 0
    GroupsAnalyzed   = 0
    GroupsCreated    = 0
    GroupsExisted    = 0
    MembershipsAdded = 0
    Errors           = 0
}

# ---------------------------------------------------------------------------
# Fonctions de Logging & UI
# ---------------------------------------------------------------------------
function Initialize-Logging {
    param([string]$Path)
    if (-not (Test-Path -Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $script:LogFile = Join-Path -Path $Path -ChildPath "AD-Provisioning-$timestamp.log"
    Write-Log "INFO" "START" "Système de journalisation initialisé : $script:LogFile"
}

function Write-Log {
    param(
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS", "WHATIF")]
        [string]$Level,
        [string]$Component,
        [string]$Message,
        [string]$Detail = ""
    )
    $timeStr = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "$timeStr [$($Level.PadRight(7))] $Component -$Message"
    if ($Detail) { $logLine += " \vert{} Detail: $Detail" }

    # Format Console
    $color = Switch ($Level) {
        "INFO"    { "Cyan" }
        "WARNING" { "Yellow" }
        "ERROR"   { "Red" }
        "SUCCESS" { "Green" }
        "WHATIF"  { "Magenta" }
    }

    Write-Host $logLine -ForegroundColor$color

    # Écriture dans le fichier de log si disponible
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value$logLine -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Vérification des Prérequis & Domaine
# ---------------------------------------------------------------------------
function Test-Environment {
    Write-Log "INFO" "PRECHECK" "Vérification de l'environnement d'exécution..."

    # Test du module AD
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw "Le module ActiveDirectory (RSAT) n'est pas installé sur cette machine."
    }
    Import-Module ActiveDirectory -ErrorAction Stop

    # Test de connectivité au domaine AD
    try {
        $domain = Get-ADDomain -ErrorAction Stop
        Write-Log "INFO" "DOMAIN" "Domaine Active Directory détecté : $($domain.DNSRoot) ($($domain.DistinguishedName))"
        return $domain
    }
    catch {
        throw "Impossible de se connecter au domaine Active Directory courant : $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Validation des Fichiers CSV
# ---------------------------------------------------------------------------
function Test-CsvFiles {
    param([string]$Path)
    Write-Log "INFO" "VALIDATION" "[1/5] Vérification de l'existence des fichiers CSV..."

    $requiredFiles = @("sites.csv", "ous.csv", "users.csv", "groups.csv", "memberships.csv")
    foreach ($file in $requiredFiles) {$filePath = Join-Path -Path $Path -ChildPath$file
        if (-not (Test-Path -Path $filePath)) {
            throw "Fichier de configuration requis manquant : $filePath"
        }
    }

    Write-Log "INFO" "VALIDATION" "[2/5] Chargement et analyse de la structure CSV..."
    $sites = Import-Csv -Path (Join-Path$Path "sites.csv")
    $users = Import-Csv -Path (Join-Path$Path "users.csv")
    $groups = Import-Csv -Path (Join-Path$Path "groups.csv")

    Write-Log "INFO" "VALIDATION" "[3/5] Validation des en-têtes obligatoires..."
    $userHeaders = @("EmployeeId","FirstName","LastName","SamAccountName","UserPrincipalName","DisplayName","Email","Department","JobTitle","Company","Country","Region","City","SiteId","Building","DepartmentOU","Enabled")
    foreach ($h in$userHeaders) {
        if (-not ($users.PSObject.Properties.Name -contains$h)) {
            throw "Colonne manquante '$h' dans users.csv"
        }
    }

    Write-Log "INFO" "VALIDATION" "[4/5] Détection des doublons et validations d'intégrité..."
    $hasErrors =$false

    # Validation doublons d'identifiants
    $empIds = $users.EmployeeId \vert{} Where-Object {$_ }
    if (($empIds \vert{} Select-Object -Unique).Count -ne$empIds.Count) {
        Write-Log "ERROR" "VALIDATION" "Des doublons de EmployeeId ont été détectés dans users.csv."
        $hasErrors =$true
    }

    $sams = $users.SamAccountName \vert{} Where-Object {$_ }
    if (($sams \vert{} Select-Object -Unique).Count -ne$sams.Count) {
        Write-Log "ERROR" "VALIDATION" "Des doublons de SamAccountName ont été détectés dans users.csv."
        $hasErrors =$true
    }

    $upns = $users.UserPrincipalName \vert{} Where-Object {$_ }
    if (($upns \vert{} Select-Object -Unique).Count -ne$upns.Count) {
        Write-Log "ERROR" "VALIDATION" "Des doublons de UserPrincipalName ont été détectés dans users.csv."
        $hasErrors =$true
    }

    # Validation Intégrité Référentielle SiteId
    $siteIds =$sites.SiteId
    foreach ($u in$users) {
        if ($u.SiteId -and ($siteIds -notcontains$u.SiteId)) {
            Write-Log "ERROR" "VALIDATION" "Utilisateur '$($u.SamAccountName)' référence un SiteId inconnu : '$($u.SiteId)'"
            $hasErrors =$true
        }
    }

    if ($hasErrors) {
        throw "La validation des fichiers CSV a échoué. Veuillez corriger les erreurs ci-dessus."
    }

    Write-Log "SUCCESS" "VALIDATION" "[5/5] Vérification terminée avec succès."
    return @{
        Sites = $sites
        OUs = Import-Csv -Path (Join-Path $Path "ous.csv")
        Users = $users
        Groups = $groups
        Memberships = Import-Csv -Path (Join-Path $Path "memberships.csv")
    }
}

# ---------------------------------------------------------------------------
# Gestion Idempotente des OU
# ---------------------------------------------------------------------------
function Ensure-OU {
    param(
        [string]$Name,
        [string]$ParentDN,
        [string]$Description = ""
    )

    $script:Stats.OUsAnalyzed++$targetDN = "OU=$Name,$ParentDN"

    try {
        $ouObj = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$targetDN'" -ErrorAction SilentlyContinue
        if ($ouObj) {$script:Stats.OUsExisted++
            Write-Log "INFO" "OU" "OU existe déjà : $targetDN"
            return $targetDN
        }

        if ($WhatIf) {$script:Stats.OUsCreated++
            Write-Log "WHATIF" "OU" "Création simulée de l'OU '$Name' sous '$ParentDN'"
            return $targetDN
        }

        New-ADOrganizationalUnit -Name $Name -Path $ParentDN -Description$Description -ProtectedFromAccidentalDeletion $false -ErrorAction Stop$script:Stats.OUsCreated++
        Write-Log "SUCCESS" "OU" "Création réussie de l'OU : $targetDN"
        return $targetDN
    }
    catch {
        $script:Stats.Errors++
        Write-Log "ERROR" "OU" "Échec de création de l'OU '$Name' dans '$ParentDN'" $_.Exception.Message
        throw $_
    }
}

# ---------------------------------------------------------------------------
# Construction Dynamique de l'Arborescence AD
# ---------------------------------------------------------------------------
function Build-ADStructure {
    param(
        [string]$DomainDN,
        [array]$Sites,
        [array]$CustomOUs
    )

    Write-Log "INFO" "STRUCTURE" "Construction de la structure des Unités d'Organisation (OU)..."

    # 1. OU Racine de l'entreprise
    $companyDN = Ensure-OU -Name "Company" -ParentDN $DomainDN -Description "OU Racine Entreprise"

    # 2. OU Spécifiques / Systèmes
    foreach ($ou in$CustomOUs) {
        if ($ou.Name -eq "Company") { continue } # Déjà géré
        $parent = if ([string]::IsNullOrWhitespace($ou.ParentPath)) { $companyDN } else { "$($ou.ParentPath),$DomainDN" }
        Ensure-OU -Name $ou.Name -ParentDN $parent -Description$ou.Description | Out-Null
    }

    # 3. Arborescence dynamique basée sur les Sites CSV
    # Structure : Company -> Region -> Country -> City -> Building -> Departments
    foreach ($site in $Sites) {$regionDN   = Ensure-OU -Name $site.Region -ParentDN$companyDN -Description "Région $($site.Region)"
        $countryDN  = Ensure-OU -Name $site.Country -ParentDN$regionDN -Description "Pays $($site.Country)"
        $cityDN     = Ensure-OU -Name $site.City -ParentDN$countryDN -Description "Ville $($site.City)"
        $bldgDN     = Ensure-OU -Name$site.Building -ParentDN $cityDN -Description$site.Description
        Ensure-OU -Name "Departments" -ParentDN $bldgDN -Description "Départements du bâtiment" | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Gestion Idempotente des Utilisateurs
# ---------------------------------------------------------------------------
function Ensure-User {
    param(
        [PSCustomObject]$UserRecord,
        [string]$DomainDN,
        [array]$Sites,
        [System.Security.SecureString]$InitialPassword
    )

    $script:Stats.UsersAnalyzed++

    # Résolution du chemin d'OU Cible d'après le SiteId
    $site =$Sites | Where-Object { $_.SiteId -eq$UserRecord.SiteId } | Select-Object -First 1
    if (-not $site) {$script:Stats.Errors++
        Write-Log "ERROR" "USER" "SiteId introuvable pour l'utilisateur '$($UserRecord.SamAccountName)'"
        return
    }

    # Construction du DN Cible : OU=<DepartmentOU>,OU=Departments,OU=<Building>,OU=<City>,OU=<Country>,OU=<Region>,OU=Company,<DomainDN>
    $deptParentDN = "OU=Departments,OU=$($site.Building),OU=$($site.City),OU=$($site.Country),OU=$($site.Region),OU=Company,$DomainDN"
    $targetOU     = Ensure-OU -Name $UserRecord.DepartmentOU -ParentDN$deptParentDN -Description "Département $($UserRecord.DepartmentOU)"

    # Vérification d'existence préalable (idempotence)
    $existingUser = Get-ADUser -Filter "EmployeeID -eq '$($UserRecord.EmployeeId)' -or SamAccountName -eq '$($UserRecord.SamAccountName)'" -ErrorAction SilentlyContinue

    if ($existingUser) {$script:Stats.UsersExisted++
        Write-Log "INFO" "USER" "Utilisateur déjà existant : $($UserRecord.SamAccountName) (EmployeeId: $($UserRecord.EmployeeId))"
        return
    }

    if ($WhatIf) {$script:Stats.UsersCreated++
        Write-Log "WHATIF" "USER" "Création simulée de l'utilisateur '$($UserRecord.SamAccountName)' dans '$targetOU'"
        return
    }

    try {
        $userParams = @{
            SamAccountName        = $UserRecord.SamAccountName
            UserPrincipalName     = $UserRecord.UserPrincipalName
            Name                  = $UserRecord.DisplayName
            DisplayName           = $UserRecord.DisplayName
            GivenName             = $UserRecord.FirstName
            Surname               = $UserRecord.LastName
            EmailAddress          = $UserRecord.Email
            EmployeeID            = $UserRecord.EmployeeId
            Department            = $UserRecord.Department
            Title                 = $UserRecord.JobTitle
            Company               = $UserRecord.Company
            City                  = $UserRecord.City
            Country               = $UserRecord.Country
            Path                  = $targetOU
            AccountPassword       = $InitialPassword
            Enabled               = [System.Convert]::ToBoolean($UserRecord.Enabled)
            ChangePasswordAtLogon = $true
            ErrorAction           = "Stop"
        }

        New-ADUser @userParams
        $script:Stats.UsersCreated++
        Write-Log "SUCCESS" "USER" "Utilisateur créé avec succès : $($UserRecord.SamAccountName)" "DN: CN=$($UserRecord.DisplayName),$targetOU"
    }
    catch {
        $script:Stats.Errors++
        Write-Log "ERROR" "USER" "Erreur lors de la création de l'utilisateur '$($UserRecord.SamAccountName)'" $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# Gestion Idempotente des Groupes & Membres
# ---------------------------------------------------------------------------
function Ensure-Group {
    param(
        [PSCustomObject]$GroupRecord,
        [string]$DomainDN
    )

    $script:Stats.GroupsAnalyzed++
    $targetOU = "OU=Groups,OU=Company,$DomainDN"

    $group = Get-ADGroup -Filter "SamAccountName -eq '$($GroupRecord.GroupName)'" -ErrorAction SilentlyContinue
    if ($group) {$script:Stats.GroupsExisted++
        Write-Log "INFO" "GROUP" "Le groupe existe déjà : $($GroupRecord.GroupName)"
        return
    }

    if ($WhatIf) {$script:Stats.GroupsCreated++
        Write-Log "WHATIF" "GROUP" "Création simulée du groupe '$($GroupRecord.GroupName)' dans '$targetOU'"
        return
    }

    try {
        New-ADGroup -Name $GroupRecord.GroupName `
                    -SamAccountName $GroupRecord.GroupName `
                    -GroupScope $GroupRecord.GroupScope `
                    -GroupCategory $GroupRecord.GroupCategory `
                    -Description $GroupRecord.Description `
                    -Path $targetOU `
                    -ErrorAction Stop

        $script:Stats.GroupsCreated++
        Write-Log "SUCCESS" "GROUP" "Groupe créé avec succès : $($GroupRecord.GroupName)"
    }
    catch {
        $script:Stats.Errors++
        Write-Log "ERROR" "GROUP" "Échec de la création du groupe '$($GroupRecord.GroupName)'" $_.Exception.Message
    }
}

function Add-GroupMemberships {
    param([array]$Memberships)

    foreach ($m in$Memberships) {
        if ($WhatIf) {
            Write-Log "WHATIF" "MEMBER" "Ajout simulé de '$($m.SamAccountName)' au groupe '$($m.GroupName)'"
            continue
        }

        try {
            $uObj = Get-ADUser -Filter "SamAccountName -eq '$($m.SamAccountName)'" -ErrorAction SilentlyContinue
            $gObj = Get-ADGroup -Filter "SamAccountName -eq '$($m.GroupName)'" -ErrorAction SilentlyContinue

            if ($uObj -and$gObj) {
                $isMember = Get-ADGroupMember -Identity$gObj | Where-Object { $_.SamAccountName -eq$uObj.SamAccountName }
                if (-not $isMember) {
                    Add-ADGroupMember -Identity $gObj -Members $uObj -ErrorAction Stop$script:Stats.MembershipsAdded++
                    Write-Log "SUCCESS" "MEMBER" "Utilisateur '$($m.SamAccountName)' ajouté au groupe '$($m.GroupName)'"
                } else {
                    Write-Log "INFO" "MEMBER" "L'utilisateur '$($m.SamAccountName)' est déjà membre du groupe '$($m.GroupName)'"
                }
            } else {
                Write-Log "WARNING" "MEMBER" "Impossible d'associer '$($m.SamAccountName)' à '$($m.GroupName)' : Utilisateur ou Groupe introuvable."
            }
        }
        catch {
            $script:Stats.Errors++
            Write-Log "ERROR" "MEMBER" "Échec de l'association membre '$($m.SamAccountName)' -> Groupe '$($m.GroupName)'" $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
# Saisie Sécurisée du Mot de Passe Initial
# ---------------------------------------------------------------------------
function Get-SecureInitialPassword {
    Write-Host "`nConfiguration du mot de passe initial des nouveaux comptes." -ForegroundColor Yellow
    Write-Host "1. Saisir un mot de passe sécurisé"
    Write-Host "2. Générer un mot de passe complexe aléatoire"
    $choice = Read-Host "Choix (1 ou 2)"

    if ($choice -eq "2") {
        $charSet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*"
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $bytes = New-Object byte[] 16
        $rng.GetBytes($bytes)
        $passStr = -join ($bytes | ForEach-Object { $charSet[$_ % $charSet.Length] })
        Write-Host "--> Mot de passe complexe généré aléatoirement pour la session de création." -ForegroundColor Cyan
        return (ConvertTo-SecureString $passStr -AsPlainText -Force)
    }
    else {
        return (Read-Host -Prompt "Saisissez le mot de passe initial Active Directory" -AsSecureString)
    }
}

# ---------------------------------------------------------------------------
# Génération du Rapport Résumé
# ---------------------------------------------------------------------------
function Write-Summary {
    param([string]$DomainName)
    $duration = (Get-Date) - $script:StartTime
    $durationStr = "{0:hh}:{0:mm}:{0:ss}" -f $duration

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "         RÉSULTAT DU PROVISIONING       " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Domaine              : $DomainName"
    Write-Host ""
    Write-Host "OU analysées          : $($script:Stats.OUsAnalyzed)"
    Write-Host "OU créées             : $($script:Stats.OUsCreated)"
    Write-Host "OU déjà existantes    : $($script:Stats.OUsExisted)"
    Write-Host ""
    Write-Host "Utilisateurs analysés : $($script:Stats.UsersAnalyzed)"
    Write-Host "Utilisateurs créés    : $($script:Stats.UsersCreated)"
    Write-Host "Utilisateurs existants: $($script:Stats.UsersExisted)"
    Write-Host ""
    Write-Host "Groupes analysés      : $($script:Stats.GroupsAnalyzed)"
    Write-Host "Groupes créés         : $($script:Stats.GroupsCreated)"
    Write-Host "Groupes existants     : $($script:Stats.GroupsExisted)"
    Write-Host ""
    Write-Host "Erreurs               : $($script:Stats.Errors)" -ForegroundColor $(if ($script:Stats.Errors -gt 0) { "Red" } else { "Green" })
    Write-Host "Durée                 : $durationStr"
    Write-Host ""
    Write-Host "Log :"
    Write-Host "$script:LogFile"
    Write-Host "========================================" -ForegroundColor Cyan

    if ($script:Stats.OUsCreated -eq 0 -and $script:Stats.UsersCreated -eq 0 -and$script:Stats.GroupsCreated -eq 0) {
        Write-Host "`nAucune modification nécessaire." -ForegroundColor Green
        Write-Host "L'annuaire Active Directory correspond déjà aux données présentes dans les CSV." -ForegroundColor Green
    } else {
        Write-Host "`nProvisioning terminé avec succès." -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Point d'Entrée Principal (Main Execution Block)
# ---------------------------------------------------------------------------
try {
    Initialize-Logging -Path $LogPath$adDomain = Test-Environment
    $domainDN =$adDomain.DistinguishedName

    # Affichage de la bannière et confirmation obligatoire
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "   ACTIVE DIRECTORY PROVISIONING TOOL   " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "`nDomaine détecté : $($adDomain.DNSRoot)" -ForegroundColor Yellow
    if ($WhatIf) {
        Write-Host "MODE SIMULATION (-WhatIf) ACTIF. Aucune modification ne sera appliquée sur AD." -ForegroundColor Magenta
    } else {
        Write-Host "`nATTENTION :" -ForegroundColor Red
        Write-Host "Ce script va analyser les fichiers CSV et créer les objets Active Directory manquants."
    }

    $confirm = Read-Host "`nContinuer ? [O] Oui / [N] Non"
    if ($confirm -notmatch '^[O\vert{}o](ui)?$') {
        Write-Log "WARNING" "STOP" "Opération annulée par l'utilisateur."
        exit 0
    }

    # Phase 1: Validation
    $data = Test-CsvFiles -Path$ConfigPath

    # Phase 2: Mot de passe initial (si non simulation)
    $securePassword =$null
    if (-not $WhatIf) {$securePassword = Get-SecureInitialPassword
    } else {
        $securePassword = ConvertTo-SecureString "DummyP@ssw0rd2026!" -AsPlainText -Force
    }

    # Phase 3: Exécution
    Write-Log "INFO" "EXEC" "Début des opérations de provisioning..."

    # 1. Structure d'OU
    Build-ADStructure -DomainDN $domainDN -Sites $data.Sites -CustomOUs$data.OUs

    # 2. Utilisateurs
    foreach ($user in$data.Users) {
        Ensure-User -UserRecord $user -DomainDN$domainDN -Sites $data.Sites -InitialPassword$securePassword
    }

    # 3. Groupes et Appartenances
    if (-not $SkipGroups) {
        foreach ($group in$data.Groups) {
            Ensure-Group -GroupRecord $group -DomainDN$domainDN
        }
        Add-GroupMemberships -Memberships $data.Memberships
    }

    # Phase 4: Bilan
    Write-Summary -DomainName $adDomain.DNSRoot
}
catch {
    Write-Log "ERROR" "FATAL" "Interruption du script suite à une erreur critique" $_.Exception.Message
    exit 1
}