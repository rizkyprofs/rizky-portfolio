# Tutorial deploy: Portfolio di K3s + AWS EC2 dengan GitOps

Panduan ini membawa kamu dari nol sampai portfolio jalan di Kubernetes (K3s) di AWS EC2, lengkap dengan HTTPS, CI/CD, dan monitoring. Istilah teknis sengaja tidak diterjemahkan supaya mudah dicari di dokumentasi resmi.

Perkiraan waktu: 2 sampai 3 jam untuk pertama kali.

## Alur yang akan kamu bangun

```
git push → GitHub Actions (build + Trivy) → Amazon ECR
        → commit tag baru ke helm/values.yaml → Argo CD sync → K3s di EC2
        → Traefik + cert-manager (HTTPS) → pengunjung
```

## 0. Persiapan dan biaya

Yang kamu butuhkan:

- Akun AWS dan AWS CLI di laptop (`aws configure`), akun GitHub, `git`.
- Domain, atau pakai `nip.io` (gratis): alamat seperti `portfolio.<ELASTIC-IP>.nip.io` otomatis mengarah ke IP tersebut dan tetap bisa dapat sertifikat Let's Encrypt.

Biaya, baca dulu:

- Cek di halaman Billing, tipe instance mana yang masuk free tier atau credit akunmu. Aturan free tier AWS berubah-ubah, jadi jangan berasumsi.
- **Pasang AWS Budgets** dulu (Billing → Budgets → Zero spend budget atau budget kecil, mis. 5 USD) supaya ada email kalau ada biaya.
- Elastic IP yang tidak terpasang ke instance, instance yang lupa dimatikan, dan data transfer keluar bisa menimbulkan biaya. Langkah 10 menjelaskan cara bersih-bersih.

Siapkan variabel di terminal laptop:

```bash
export AWS_REGION=ap-southeast-1          # Singapore, region default yang aktif
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export GITHUB_REPO=rizkyprofs/rizky-portfolio   # ganti sesuai repomu
export ECR_REPOSITORY=rizky-portfolio
```

## 1. Push repo ke GitHub

```bash
cd rizky-portfolio
git init -b main
git add .
git commit -m "feat: initial portfolio"
git remote add origin git@github.com:$GITHUB_REPO.git
git push -u origin main
```

Workflow pertama akan gagal di langkah AWS karena variabelnya belum ada. Itu normal, kita perbaiki di langkah 6.

## 2. Siapkan AWS: ECR dan IAM

### 2.1 ECR repository (+ hapus image lama otomatis)

```bash
aws ecr create-repository --repository-name $ECR_REPOSITORY --region $AWS_REGION \
  --image-scanning-configuration scanOnPush=true

aws ecr put-lifecycle-policy --repository-name $ECR_REPOSITORY --region $AWS_REGION \
  --lifecycle-policy-text file://aws/ecr-lifecycle.json
```

Lifecycle policy menyimpan 5 image terakhir saja, supaya storage ECR tidak membengkak.

### 2.2 IAM role untuk GitHub Actions (OIDC, tanpa access key)

```bash
# Sekali per akun AWS. Kalau error "EntityAlreadyExists", lewati saja.
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com

# Isi placeholder di file policy
sed -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" -e "s|<GITHUB_REPO>|$GITHUB_REPO|g" \
  aws/github-oidc-trust.json > /tmp/gh-trust.json
sed -e "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" -e "s|<AWS_REGION>|$AWS_REGION|g" \
  -e "s|<ECR_REPOSITORY>|$ECR_REPOSITORY|g" \
  aws/github-ecr-push-policy.json > /tmp/gh-push.json

aws iam create-role --role-name portfolio-github-ci \
  --assume-role-policy-document file:///tmp/gh-trust.json
aws iam put-role-policy --role-name portfolio-github-ci \
  --policy-name ecr-push --policy-document file:///tmp/gh-push.json

echo "AWS_ROLE_ARN = arn:aws:iam::$ACCOUNT_ID:role/portfolio-github-ci"
```

Catat nilai `AWS_ROLE_ARN` untuk langkah 6. Role ini hanya bisa dipakai oleh branch `main` di repomu dan hanya boleh push ke satu repository ECR.

### 2.3 IAM role untuk EC2 (supaya K3s boleh pull image dari ECR)

```bash
aws iam create-role --role-name portfolio-ec2 \
  --assume-role-policy-document file://aws/ec2-trust.json
aws iam attach-role-policy --role-name portfolio-ec2 \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam create-instance-profile --instance-profile-name portfolio-ec2
aws iam add-role-to-instance-profile --instance-profile-name portfolio-ec2 \
  --role-name portfolio-ec2
```

## 3. Buat EC2

Lewat AWS Console (EC2 → Launch instance):

| Setting | Nilai |
| --- | --- |
| AMI | Ubuntu Server 24.04 LTS |
| Instance type | Yang paling besar yang masih gratis di akunmu. Idealnya 2 GB RAM (mis. t3.small). 1 GB (t3.micro) bisa jalan tapi mepet, lihat catatan swap di bawah. |
| Key pair | Buat baru, simpan file `.pem` |
| Storage | 20 GB gp3 |
| IAM instance profile (Advanced details) | `portfolio-ec2` |

Security group (inbound):

| Port | Source | Untuk |
| --- | --- | --- |
| 22 | IP kamu saja (My IP) | SSH |
| 80 | 0.0.0.0/0 | HTTP dan validasi Let's Encrypt |
| 443 | 0.0.0.0/0 | HTTPS |

Jangan buka port 6443 (API Kubernetes) ke internet. Kita akses cluster lewat SSH.

Lalu: EC2 → Elastic IPs → Allocate → Associate ke instance. Catat IP-nya. Host sitemu nanti: `portfolio.<ELASTIC-IP>.nip.io`.

Masuk ke server dan tambah swap (penting untuk RAM kecil):

```bash
chmod 400 your-key.pem
ssh -i your-key.pem ubuntu@<ELASTIC-IP>

sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```

## 4. Install K3s (+ credential provider untuk ECR)

Kubelet K3s tidak otomatis memakai IAM role instance untuk pull dari ECR. Solusinya `ecr-credential-provider`, yang menukar IAM role menjadi token ECR secara otomatis.

Jalankan di server:

```bash
# 4.1 Binary credential provider (arsitektur t3 = amd64, t4g = arm64)
sudo mkdir -p /var/lib/rancher/credentialprovider/bin
VERSION=v1.31.0   # cek versi terbaru di github.com/kubernetes/cloud-provider-aws/releases
sudo curl -fL -o /var/lib/rancher/credentialprovider/bin/ecr-credential-provider \
  https://artifacts.k8s.io/binaries/cloud-provider-aws/$VERSION/linux/amd64/ecr-credential-provider-linux-amd64
sudo chmod +x /var/lib/rancher/credentialprovider/bin/ecr-credential-provider

# 4.2 Config provider
sudo tee /var/lib/rancher/credentialprovider/config.yaml >/dev/null <<'YAML'
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
YAML

# 4.3 Config K3s (ganti <ELASTIC-IP>)
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<'YAML'
write-kubeconfig-mode: "644"
tls-san:
  - <ELASTIC-IP>
kubelet-arg:
  - "image-credential-provider-config=/var/lib/rancher/credentialprovider/config.yaml"
  - "image-credential-provider-bin-dir=/var/lib/rancher/credentialprovider/bin"
YAML

# 4.4 Install K3s (Traefik ikut terpasang secara default)
curl -sfL https://get.k3s.io | sh -
sudo systemctl status k3s --no-pager | head -5

# 4.5 kubectl dan Helm
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
source ~/.bashrc
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

kubectl get nodes
kubectl -n kube-system get pods
```

Node harus `Ready`, dan pod `traefik` harus `Running`. Kalau URL download binary di 4.1 error 404, buka halaman releases dan sesuaikan `VERSION`.

Kenapa Traefik, bukan ingress-nginx? Proyek ingress-nginx resmi pensiun Maret 2026 dan tidak lagi menerima perbaikan keamanan. K3s sudah membawa Traefik, jadi lebih aman dan lebih hemat RAM.

## 5. Install cert-manager

Masih di server. Clone repomu dulu supaya file `k8s/` tersedia:

```bash
git clone https://github.com/$GITHUB_REPO.git ~/rizky-portfolio   # ganti $GITHUB_REPO manual jika variabel tidak ada di server
cd ~/rizky-portfolio

helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --set crds.enabled=true

kubectl -n cert-manager get pods     # tunggu semuanya Running
kubectl apply -f k8s/cluster-issuer.yaml
kubectl get clusterissuer
```

Ada dua issuer: `letsencrypt-staging` (untuk latihan, tidak kena rate limit tapi browser tidak percaya) dan `letsencrypt-prod`. Mulai dari staging.

## 6. Konfigurasi GitHub dan jalankan pipeline pertama

Di laptop, edit `helm/portfolio/values.yaml`:

```yaml
ingress:
  host: portfolio.<ELASTIC-IP>.nip.io     # atau domainmu
```

Commit dan push. Lalu di GitHub: Settings → Secrets and variables → Actions → tab **Variables**, tambahkan:

| Name | Value |
| --- | --- |
| `AWS_REGION` | `ap-southeast-1` |
| `ECR_REPOSITORY` | `rizky-portfolio` |
| `AWS_ROLE_ARN` | ARN dari langkah 2.2 |

Kalau kamu mengaktifkan branch protection di `main`, izinkan `github-actions[bot]` untuk push, karena workflow meng-commit tag image baru ke `helm/portfolio/values.yaml`.

Jalankan ulang workflow (Actions → ci → Re-run, atau push commit kecil). Hasil yang benar:

- Step Trivy hijau.
- Image muncul di ECR: `aws ecr list-images --repository-name $ECR_REPOSITORY --region $AWS_REGION`
- Ada commit baru `chore: deploy <sha> [skip ci]` dari bot yang mengubah `tag` di `values.yaml`.

Kalau Trivy gagal karena CVE di base image, itu pipeline bekerja sesuai desain. Rebuild untuk menarik base image terbaru, atau cek temuannya di log.

## 7. Install Argo CD dan hubungkan ke repo

Di server (`git pull` dulu di `~/rizky-portfolio` supaya dapat commit bot):

```bash
cd ~/rizky-portfolio && git pull

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  -f argocd/values.yaml

kubectl -n argocd get pods            # tunggu Running

# Sesuaikan repoURL di argocd/application.yaml jika nama repomu berbeda, lalu:
kubectl apply -f argocd/application.yaml
kubectl -n argocd get applications
```

Status harus menjadi `Synced` dan `Healthy`. Repo publik tidak butuh credential di Argo CD. Kalau repomu private, tambahkan repo credential lewat UI atau CLI Argo CD.

Buka UI Argo CD lewat SSH tunnel (tanpa membuka port ke internet):

```bash
# di laptop
ssh -i your-key.pem -L 8080:localhost:8080 ubuntu@<ELASTIC-IP>
# di dalam sesi SSH itu
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Buka `https://localhost:8080`, user `admin`, password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## 8. Verifikasi

```bash
kubectl -n portfolio get pods,svc,ingress
kubectl -n portfolio get certificate        # READY harus True setelah 1 sampai 2 menit
curl -I https://portfolio.<ELASTIC-IP>.nip.io
```

Dengan issuer staging, `curl` akan mengeluh sertifikat tidak dipercaya. Itu benar untuk staging. Kalau `Certificate` sudah `READY=True`, ganti ke produksi:

1. Di `helm/portfolio/values.yaml`, ubah `clusterIssuer: letsencrypt-prod`.
2. Commit dan push (workflow tidak jalan karena `helm/**` diabaikan, dan Argo CD akan sync sendiri dalam beberapa menit).
3. Hapus secret lama supaya sertifikat baru dibuat: `kubectl -n portfolio delete secret portfolio-tls`.
4. Cek ulang `kubectl -n portfolio get certificate` dan buka situsnya di browser.

Cek juga security headers: `curl -sI https://portfolio.<ELASTIC-IP>.nip.io | grep -i -E 'content-security|x-frame|nosniff'`.

## 9. Monitoring (opsional, makan RAM)

```bash
cd ~/rizky-portfolio
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f monitoring/values.yaml \
  --set grafana.adminPassword='GANTI-PASSWORD-INI'

kubectl -n monitoring get pods
kubectl top nodes
```

Akses Grafana lewat tunnel, sama seperti Argo CD:

```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
# laptop: ssh -L 3000:localhost:3000 ... lalu buka http://localhost:3000
```

Dashboard bawaan seperti "Kubernetes / Compute Resources / Namespace (Pods)" dan "Node Exporter" sudah tersedia. Kalau `kubectl top nodes` menunjukkan memori hampir penuh, naikkan ukuran instance atau matikan stack ini dulu.

Loki (log) belum disiapkan di repo ini. Kalau sudah kamu pasang sendiri, biarkan chip "Loki" di web. Kalau belum, hapus chip itu dari `site/index.html` supaya portfolio hanya menampilkan yang benar-benar jalan.

## 10. Operasi harian, rollback, dan bersih-bersih

Deploy versi baru: edit `site/index.html`, commit, push. Selesai.

Rollback: cari commit bot yang bermasalah di `helm/portfolio/values.yaml`, lalu:

```bash
git revert <commit-sha> && git push
```

Argo CD akan mengembalikan tag image sebelumnya. Image lama masih ada di ECR selama belum kena lifecycle policy (5 terakhir).

Bersih-bersih setelah selesai belajar, supaya tidak ada tagihan:

1. Terminate EC2 instance.
2. Release Elastic IP (EC2 → Elastic IPs → Release).
3. Hapus repository ECR: `aws ecr delete-repository --repository-name $ECR_REPOSITORY --force --region $AWS_REGION`
4. Hapus IAM role `portfolio-github-ci` dan `portfolio-ec2` beserta instance profile.
5. Hapus EBS volume yang tersisa dan cek halaman Billing besoknya.

## Troubleshooting

| Gejala | Penyebab umum | Cara cek dan perbaiki |
| --- | --- | --- |
| Pod `ImagePullBackOff` | Credential provider belum aktif, atau instance profile belum terpasang | `kubectl -n portfolio describe pod`. Pastikan langkah 4.1 sampai 4.3 selesai sebelum K3s di-install, lalu `sudo systemctl restart k3s`. Cek IAM role terpasang di instance. |
| Pod `ImagePullBackOff` dengan tag `bootstrap` | CI belum pernah berhasil push | Selesaikan langkah 6, lalu `git pull` di server dan tunggu Argo CD sync. |
| Certificate tidak pernah `READY` | Port 80 tertutup, host salah, atau DNS belum mengarah | `kubectl -n portfolio describe certificate,order,challenge`. Cek security group port 80 dan hostname. |
| Workflow gagal: `Could not assume role` | Trust policy tidak cocok dengan repo atau branch | Cek `GITHUB_REPO` di file trust (huruf besar kecil berpengaruh) dan workflow berjalan dari `main`. |
| Workflow gagal saat `git push` | Branch protection memblokir bot | Izinkan `github-actions[bot]` bypass, atau pindahkan tag bump ke repo manifest terpisah. |
| Argo CD `OutOfSync` terus | `repoURL` salah atau repo private | `kubectl -n argocd describe application portfolio`. |
| Server lambat, pod di-restart (OOMKilled) | RAM habis | `free -h`, `kubectl top nodes`. Tambah swap, matikan monitoring, atau naikkan tipe instance. |
| Trivy gagal di PR | CVE HIGH/CRITICAL di base image | Baca log Trivy. Biasanya cukup rebuild agar dapat base image terbaru. |

## Langkah lanjutan

- Redirect HTTP ke HTTPS dengan Traefik Middleware.
- Tambah Loki + Promtail untuk log, lalu tampilkan di Grafana.
- Ganti SSH key ke AWS Systems Manager Session Manager supaya port 22 bisa ditutup.
- Pindahkan pembuatan infrastruktur AWS ke Terraform.
