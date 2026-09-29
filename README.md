# vitamin-packs website

## Staff access to InvenTree (Windows jumpbox)

> **Status: planned procedure.** The resources below are defined in `infra/` once implemented. Names such as `vitamin-packs-prod-jumpbox` are the intended Terraform names and outputs (`vitamin-packs` is the Terraform `project` value; use `dev` in place of `prod` for dev), not proof that anything is deployed. The design and its rationale are in [docs/inventree-integration.md](docs/inventree-integration.md#staff-access).

InvenTree has no public address. You reach it from a Windows jumpbox inside the AWS VPC. Your laptop connects to the jumpbox with Remote Desktop through an AWS Systems Manager (SSM) tunnel, so no inbound ports are opened anywhere. These steps are written for **Windows 11 and PowerShell**.

```text
Windows 11 laptop
  -- aws sso login (IAM Identity Center + MFA)
  -- SSM port-forward: localhost:13389 -> jumpbox:3389 (no inbound ports)
  -- Remote Desktop (mstsc), drive T: redirected for file transfer
     -> Windows jumpbox -> Edge -> https://inventree.vitamin-packs.com (prod)
                                   https://inventree.dev.vitamin-packs.com (dev)
```

| Environment | InvenTree URL | AWS CLI profile |
|---|---|---|
| prod | `https://inventree.vitamin-packs.com` | `vp-prod-operator` |
| dev | `https://inventree.dev.vitamin-packs.com` | `vp-dev-operator` |

### One-time laptop setup

1. Install the [AWS CLI v2 for Windows](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (MSI installer) and the [Session Manager plugin for Windows](https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-windows.html). Open a new PowerShell window and check both:

   ```powershell
   aws --version
   session-manager-plugin
   ```

   The second command should print a message saying the plugin was installed successfully.

2. Create an SSO profile for each environment you use. When prompted, enter the IAM Identity Center start URL, region `us-west-2`, the AWS account, and the permission set `inventree-<env>-operator`:

   ```powershell
   aws configure sso --profile vp-prod-operator
   aws configure sso --profile vp-dev-operator
   ```

3. Create the transfer folder and map it to drive `T:`. Only this drive is shared with the jumpbox.

   ```powershell
   New-Item -ItemType Directory -Force "$env:USERPROFILE\InvenTree-Transfer"
   subst T: "$env:USERPROFILE\InvenTree-Transfer"
   ```

   `subst` mappings are lost at sign-out. To make it permanent, press Win+R, open `shell:startup`, and create a shortcut with the target `C:\Windows\System32\subst.exe T: "%USERPROFILE%\InvenTree-Transfer"`.

### Each session

Run these in PowerShell. The examples use prod; for dev, use `vp-dev-operator` and `dev` in the names.

1. **Sign in to AWS.** Your browser opens for the Identity Center sign-in and MFA.

   ```powershell
   $AwsProfile = "vp-prod-operator"
   aws sso login --profile $AwsProfile
   ```

2. **Dev only: start the dev environment first.** Dev is stopped every night. Start it in this order: RDS, then the NAT instance, then the InvenTree host. A dev start script under `scripts/` is planned; until it exists, follow the start order in [docs/inventree-integration.md](docs/inventree-integration.md#dev-vs-prod-and-cost).

3. **Start the jumpbox.** It normally runs zero instances and costs nothing while stopped.
   - In the AWS console: **EC2 → Auto Scaling groups → `vitamin-packs-prod-jumpbox` → Edit → Desired capacity `1` → Update**.
   - Or from PowerShell:

     ```powershell
     aws autoscaling set-desired-capacity --auto-scaling-group-name vitamin-packs-prod-jumpbox --desired-capacity 1 --profile $AwsProfile
     ```

   This is a deliberate change to AWS resources. Wait 5–10 minutes for Windows to boot and register with SSM. If the jumpbox stays running for 8 hours, you get a reminder email.

4. **Find the jumpbox instance ID:**

   ```powershell
   $Id = aws ec2 describe-instances --profile $AwsProfile `
     --filters "Name=tag:Name,Values=vitamin-packs-prod-jumpbox" "Name=instance-state-name,Values=running" `
     --query "Reservations[].Instances[].InstanceId" --output text
   $Id
   ```

5. **Start the tunnel** and leave this window open for the whole session:

   ```powershell
   aws ssm start-session --profile $AwsProfile --target $Id `
     --document-name AWS-StartPortForwardingSession `
     --parameters "portNumber=3389,localPortNumber=13389"
   ```

   Wait until it prints `Waiting for connections...`.

6. **In a second PowerShell window, get the RDP certificate thumbprint and copy the password to the clipboard.** The password never appears on screen.

   ```powershell
   $AwsProfile = "vp-prod-operator"
   aws ssm get-parameter --profile $AwsProfile --name /vitamin-packs/prod/jumpbox/rdp-thumbprint --query Parameter.Value --output text
   aws secretsmanager get-secret-value --profile $AwsProfile --secret-id vitamin-packs-prod-jumpbox-login --query SecretString --output text | Set-Clipboard
   ```

7. **Connect with Remote Desktop:**
   1. Run:

      ```powershell
      mstsc /v:localhost:13389
      ```

   2. Before connecting, choose **Show Options → Local Resources**. Keep **Clipboard** ticked. Under **More…**, tick **only** drive `T:`, not your other drives.
   3. Connect as `inventree-operator` and paste the password.
   4. On the first connection, Windows warns about the certificate. Choose **View certificate → Details** and continue only if the **Thumbprint** matches the value from step 6.
   5. After signing in, clear your clipboard:

      ```powershell
      Set-Clipboard -Value $null
      ```

8. **Open InvenTree.** In the jumpbox, open Microsoft Edge, go to `https://inventree.vitamin-packs.com` (dev: `https://inventree.dev.vitamin-packs.com`), and sign in to InvenTree with your InvenTree account and MFA code.

### Transferring files

- **Laptop → InvenTree** (part images, datasheets, invoices, CSV/XLSX imports, label templates):
  1. Put the file in `InvenTree-Transfer` on your laptop.
  2. In InvenTree's upload dialog on the jumpbox, browse to **This PC → T on <your laptop name>**.
- **InvenTree → laptop** (exports, PDF reports, labels): save the file on the jumpbox, then copy it to **T on <your laptop name>**. It appears in your laptop's `InvenTree-Transfer` folder.
- Delete files from the jumpbox's Downloads folder when you're done. The jumpbox is disposable and is rebuilt on every start, so nothing stored on it is kept.

### Ending a session

1. In the jumpbox, **sign out of Windows** (Start → your account → Sign out). Don't just close the Remote Desktop window.
2. Press **Ctrl+C** in the tunnel window.
3. **Stop the jumpbox:** set the desired capacity back to `0`, either in the console as in step 3 or with:

   ```powershell
   aws autoscaling set-desired-capacity --auto-scaling-group-name vitamin-packs-prod-jumpbox --desired-capacity 0 --profile $AwsProfile
   ```

   The instance and its disk are deleted, and charges stop.
4. Dev only: the dev environment stops automatically overnight.

### Fallback: browser-only access (no local tools)

If you can't use the AWS CLI or the tunnel:
1. Start the jumpbox (step 3).
2. In the AWS console, open **Systems Manager → Fleet Manager**, select the jumpbox, and choose **Node actions → Connect with Remote Desktop**.
3. Choose **User credentials** and sign in as `inventree-operator` with the password from Secrets Manager.

**Never choose the IAM Identity Center / single sign-on option.** It creates a permanent local Administrator account on the jumpbox.

The fallback has limits: sessions end after 60 minutes (you can renew them) or after 10 idle minutes, only text can be copied and pasted, and **files cannot be transferred**.

### Troubleshooting

| Symptom | Fix |
|---|---|
| `TargetNotConnected` when starting the tunnel | The jumpbox isn't running yet, or hasn't registered with SSM. Wait 5–10 minutes after starting it. If it still fails, the NAT instance may be down; SSM traffic goes through it. Check the `vitamin-packs-<env>-nat` Auto Scaling group. |
| `SessionManagerPlugin is not found` | Reinstall the Session Manager plugin, then open a new PowerShell window. |
| Port 13389 already in use | Change `localPortNumber` to another free port and use the same port in `mstsc /v:localhost:<port>`. |
| RDP rejects the password | The password may have been rotated. Copy it again (step 6). If it still fails, stop and restart the jumpbox so it picks up the current password. |
| Drive `T:` doesn't appear in the jumpbox | Check that `subst` is active on the laptop (`subst` with no arguments lists mappings) and that only `T:` is ticked under Local Resources → More. |
| Edge can't resolve the InvenTree address | Check that you used the right environment's URL. If the InvenTree host was just replaced, wait a minute for its DNS record to update. |
| AWS commands fail with expired credentials | Run `aws sso login --profile $AwsProfile` again. |

### Security notes

- No SSH or RDP port is open to the internet or the VPC. All access goes through SSM, with Identity Center and MFA.
- The jumpbox can't browse the internet: its firewall allows Edge to reach only addresses inside the VPC.
- Redirect only drive `T:`, never your whole disk. Don't save the RDP password in `mstsc`.
- The owner rotates the jumpbox password monthly by storing a new secret value; the next jumpbox start applies it. Rotation of the other InvenTree credentials is described in [docs/inventree-integration.md](docs/inventree-integration.md#secret-rotation).
