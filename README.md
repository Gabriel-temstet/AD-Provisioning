# AD Provisioning Tool - Laboratoire Enterprise

Outil PowerShell complet de provisioning et de maintenance idempotente pour Active Directory.

## 1. Prérequis et Installation

* **Système d'exploitation :** Windows Server 2016/2019/2022 (Contrôleur de domaine ou serveur membre) ou Windows 10/11 avec RSAT.
* **Module PowerShell :** `ActiveDirectory` (Inclus dans les Outils d'administration de serveur distant - RSAT).
* **Droits d'accès :** Compte membre des groupes `Domain Admins` ou disposant des délégations nécessaires pour créer des OU, Utilisateurs et Groupes.
* **PowerShell Version :** Compatible Windows PowerShell 5.1 et PowerShell 7.x (Core).

## 2. Préparation des Fichiers CSV

Renseignez les fichiers CSV situés dans le dossier `./config` :
* `sites.csv` : Déclare la hiérarchie géographique et physique (Continent, Pays, Ville, Bâtiment).
* `ous.csv` : Déclare les OU système ou transversales.
* `users.csv` : Liste des comptes utilisateurs avec attribution au site et au département.
* `groups.csv` : Liste des groupes de sécurité à instancier.
* `memberships.csv` : Affectation des utilisateurs dans les groupes.

## 3. Guide d'Utilisation

### Effectuer une Simulation (Mode WhatIf)
Permet de valider la syntaxe, l'intégrité des CSV et de visualiser toutes les créations sans altérer Active Directory :
```powershell
.\Invoke-ADProvisioning.ps1 -WhatIf

Lancer le Provisioning Réel
```powershell
.\Invoke-ADProvisioning.ps1

Exécuter avec des Chemins Personnalisés
```powershell
.\Invoke-ADProvisioning.ps1 -ConfigPath "D:\ADConfig" -LogPath "D:\ADLogs"

## 4. Maintenance de l'Annuaire

### Ajouter un nouvel utilisateur
- Ajoutez simplement la ligne du nouvel utilisateur dans config/users.csv.
- Relancez le script .\Invoke-ADProvisioning.ps1.
Le script analysera l'annuaire, détectera que tous les autres objets existent déjà (ALREADY_EXISTS), et créera uniquement le nouveau compte.

### Modifier un utilisateur existant
Conformément aux contraintes de sécurité d'un laboratoire, le script est idempotent et non destructif :
- Les attributs d'un utilisateur existant ne sont pas modifiés.
- Si un objet est retiré d'un CSV, il n'est jamais supprimé d'Active Directory. Le CSV sert de source de provisioning, pas de moteur de suppression synchrone.


### 5. Exploitation des Logs
Chaque exécution génère un fichier daté dans le dossier ./logs/ (ex: AD-Provisioning-2026-09-25_103015.log).
Les entrées de log respectent la structure : Horodatage [Niveau] Composant - Action | Détails

### 6. Restauration / Retour à l'état précédent
Si vous devez réinitialiser l'annuaire de test :

1. Les suppressions automatiques étant volontairement désactivées pour éviter les catastrophes en laboratoire, vous devez supprimer manuellement la sous-arborescence de test (OU=Company,DC=domain,DC=local).
2. Vous pouvez ensuite corriger vos CSV et relancer le script à zéro.


### 7. Notes d'Adaptation PowerShell 7
Sur PowerShell 7 (Core), assurez-vous d'importer le module Active Directory via la couche de compatibilité si RSAT n'est pas nativement compilé : Import-Module ActiveDirectory -UseWindowsPowerShell

---

### Vérifications et Auto-Correction Appliquées

1. **Idempotence stricte :** L'existence de chaque OU, Utilisateur ou Groupe est vérifiée via `Get-AD*` avant tout appel à `New-AD*`.
2. **Absence d'exposition de secrets :** Les mots de passe sont traités au format `SecureString` en mémoire et ne sont jamais journalisés dans les fichiers de log ou affichés dans le terminal.
3. **Sécurité des opérations :** Implémentation du switch `-WhatIf` ainsi que de la validation intègre des fichiers CSV (détection des doublons d'UPN/SAM/EmployeeId avant tout appel Active Directory).
4. **Calcul dynamique LDAP :** Le DistinguishedName du domaine est extrait dynamiquement via `Get-ADDomain`, évitant ainsi le codage en dur de domaines spécifiques (`DC=CONTOSO,DC=LOCAL`).