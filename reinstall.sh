#!/usr/bin/env bash
set -euo pipefail

#----------------------------------------
# Basit log fonksiyonları
#----------------------------------------
log()  { echo -e "\e[1;32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*" >&2; }
err()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

#----------------------------------------
# ROOT kontrolü
#----------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  err "Bu script root olarak çalıştırılmalı. (sudo su - && bash $0)"
fi

export DEBIAN_FRONTEND=noninteractive

#----------------------------------------
# AYARLANABİLİR DEĞİŞKENLER
#----------------------------------------

DOC_ROOT="${DOC_ROOT:-/home/gemstone/Documents}"
DOC_DIR="${DOC_ROOT}/iptablesgemstone"

ZIP_URL="https://github.com/MehmetEmreee/iptablesgemstone/raw/main/ip6table-packages.zip"
ZIP_PATH="${DOC_DIR}/ip6table-packages.zip"

OS_AGENT_VERSION="1.8.0"
OS_AGENT_ARCH="aarch64"
OS_AGENT_DEB_NAME="os-agent_${OS_AGENT_VERSION}_linux_${OS_AGENT_ARCH}.deb"
OS_AGENT_URL="https://github.com/home-assistant/os-agent/releases/download/${OS_AGENT_VERSION}/${OS_AGENT_DEB_NAME}"
OS_AGENT_TMP="/tmp/os-agent.deb"

HA_SUP_TMP="/tmp/homeassistant-supervised.deb"
HA_SUP_URL="https://github.com/home-assistant/supervised-installer/releases/latest/download/homeassistant-supervised.deb"

PATCH_DIR="/tmp/ha-supervised"
PATCHED_DEB="/tmp/homeassistant-supervised-patched.deb"

# Docker'ın kendisini de kaldırıp kaldırmayacağınızı burada seçin.
# true  -> docker engine dahil tamamen kaldırılır (en temiz sıfırlama)
# false -> sadece Home Assistant / Supervisor / os-agent kaldırılır, docker kalır
REMOVE_DOCKER="${REMOVE_DOCKER:-false}"

#----------------------------------------
# 1) MEVCUT KURULUMU TEMİZLEME (UNINSTALL)
#----------------------------------------

log "===== Home Assistant Supervised ve TÜM VERİLERİ kaldırılıyor ====="
warn "Bu işlem kullanıcılarınız, Home Assistant 'ev' konfigürasyonunuz, entegrasyonlarınız ve add-on verileriniz dahil HER ŞEYİ kalıcı olarak siler. Geri dönüşü yoktur."

log "hassio-supervisor / hassio-apparmor systemd servisleri durduruluyor..."
systemctl stop hassio-supervisor.service 2>/dev/null || true
systemctl stop hassio-apparmor.service 2>/dev/null || true
systemctl disable hassio-supervisor.service 2>/dev/null || true

if command -v docker >/dev/null 2>&1; then
  log "Supervisor/HA ile ilgili çalışan TÜM container'lar durduruluyor ve siliniyor..."
  # hassio_ ile başlayan tüm container'ları (supervisor, audio, dns, cli, multicast, observer, addon'lar) durdur ve sil
  mapfile -t ha_containers < <(docker ps -a --format '{{.Names}}' | grep -E '^hassio_|^homeassistant$|^addon_' || true)
  if (( ${#ha_containers[@]} > 0 )); then
    for c in "${ha_containers[@]}"; do
      log "Container durduruluyor ve siliniyor: ${c}"
      docker rm -f "${c}" >/dev/null 2>&1 || warn "Container silinemedi: ${c}"
    done
  else
    log "Kaldırılacak hassio/homeassistant container'ı bulunamadı."
  fi

  log "Home Assistant/Supervisor ile ilgili docker image'ları siliniyor..."
  mapfile -t ha_images < <(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -E 'homeassistant|hassio|home-assistant' || true)
  if (( ${#ha_images[@]} > 0 )); then
    for line in "${ha_images[@]}"; do
      img_id="$(awk '{print $2}' <<< "${line}")"
      log "Image siliniyor: ${line}"
      docker rmi -f "${img_id}" >/dev/null 2>&1 || warn "Image silinemedi: ${line}"
    done
  else
    log "Kaldırılacak homeassistant/hassio image'ı bulunamadı."
  fi

  log "Home Assistant/hassio ile ilgili docker volume'ları siliniyor..."
  mapfile -t ha_volumes < <(docker volume ls --format '{{.Name}}' | grep -E 'hassio|homeassistant' || true)
  if (( ${#ha_volumes[@]} > 0 )); then
    for v in "${ha_volumes[@]}"; do
      log "Volume siliniyor: ${v}"
      docker volume rm -f "${v}" >/dev/null 2>&1 || warn "Volume silinemedi: ${v}"
    done
  fi
  docker volume prune -f >/dev/null 2>&1 || true

  # /usr/share/hassio içindeki bind mount'ların silmeyi engellememesi için
  # docker'ı tamamen durduruyoruz, sonra dosya silme işlemini yapıyoruz.
  log "Bind mount'ların silmeyi engellememesi için docker servisi durduruluyor..."
  systemctl stop docker.socket 2>/dev/null || true
  systemctl stop docker 2>/dev/null || true
else
  warn "docker bulunamadı, container/image/volume temizleme adımı atlanıyor."
fi

log "homeassistant-supervised ve os-agent paketleri kaldırılıyor..."
apt remove -y --purge homeassistant-supervised os-agent 2>/dev/null || warn "Paketler zaten kurulu değil ya da kaldırılamadı."
apt autoremove -y || true

log "Home Assistant verilerinin durduğu klasörler siliniyor (config, kullanıcılar, add-on'lar, yedekler)..."
HA_DATA_PATHS=(
  /usr/share/hassio
  /etc/hassio.json
  /var/lib/hassio
  /mnt/data/supervisor
)

for p in "${HA_DATA_PATHS[@]}"; do
  if [[ -e "${p}" ]]; then
    # Hala meşgul (mounted) olabilir ihtimaline karşı önce umount deneyelim
    umount -R "${p}" 2>/dev/null || true
    rm -rf "${p}"
    if [[ -e "${p}" ]]; then
      err "SİLİNEMEDİ: ${p} — muhtemelen hâlâ bir process tarafından kullanılıyor. 'sudo lsof +D ${p}' ile kontrol edip tekrar deneyin."
    else
      log "Silindi: ${p}"
    fi
  fi
done

if [[ "${REMOVE_DOCKER}" == "true" ]]; then
  log "REMOVE_DOCKER=true, docker motoru tamamen kaldırılıyor..."
  systemctl stop docker 2>/dev/null || true
  apt remove -y --purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
  rm -rf /var/lib/docker /var/lib/containerd 2>/dev/null || true
fi

log "İndirilen eski geçici dosyalar temizleniyor..."
rm -f "${OS_AGENT_TMP}" "${HA_SUP_TMP}" "${PATCHED_DEB}"
rm -rf "${PATCH_DIR}"

if [[ "${REMOVE_DOCKER}" != "true" ]] && command -v docker >/dev/null 2>&1; then
  log "Docker motoru korunuyor, temizlik için durdurulmuştu, tekrar başlatılıyor..."
  systemctl start docker 2>/dev/null || warn "Docker tekrar başlatılamadı, kurulum adımında get.docker.com çalıştırılacak."
fi

log "===== Temizlik tamamlandı, kuruluma geçiliyor ====="

#----------------------------------------
# 2) YENİDEN KURULUM (INSTALL)
#----------------------------------------

log "apt update çalıştırılıyor..."
apt update -y

log "unzip ve curl kuruluyor (script için)..."
apt install -y unzip curl debconf-utils

log "Documents klasörleri hazırlanıyor: ${DOC_DIR}"
mkdir -p "${DOC_DIR}"

log "Zip dosyası GitHub'dan indiriliyor: ${ZIP_URL}"
curl -fL -o "${ZIP_PATH}" "${ZIP_URL}"

log "Zip çıkarılıyor: ${ZIP_PATH} -> ${DOC_DIR}"
unzip -q -o "${ZIP_PATH}" -d "${DOC_DIR}"

log "kernel-module-*.deb paketleri bulunup kuruluyor..."
shopt -s nullglob
mapfile -t deb_files < <(printf '%s\n' "${DOC_DIR}"/kernel-module-*.deb)
shopt -u nullglob

if (( ${#deb_files[@]} == 0 )); then
  err "${DOC_DIR} içinde kernel-module-*.deb bulunamadı."
fi

for deb in "${deb_files[@]}"; do
  log "dpkg -i ${deb}"
  dpkg -i "${deb}" || warn "dpkg -i sırasında hata: ${deb} (apt -f install ile düzeltilecek)"
done

log "Bağımlılık düzeltmesi için apt -f install çalıştırılıyor..."
apt -f install -y || warn "apt -f install bazı şeyleri düzeltemedi, ama devam ediyorum."

log "network-manager ve systemd-resolved kuruluyor..."
apt install -y \
  network-manager \
  systemd-resolved

log "Ağ servisi migration komutları çalıştırılıyor..."
systemctl restart systemd-resolved.service || warn "systemd-resolved restart başarısız görünüyor."

if systemctl list-unit-files | grep -q "^networking.service"; then
  systemctl disable --now networking.service || warn "networking.service devre dışı bırakılamadı."
fi

if [[ -f /etc/network/interfaces ]]; then
  mv /etc/network/interfaces /etc/network/interfaces.disabled
  log "/etc/network/interfaces -> /etc/network/interfaces.disabled taşındı."
fi

systemctl restart NetworkManager || warn "NetworkManager restart başarısız olabilir, elle kontrol et."

log "curl ve udisks2 kuruluyor..."
apt install -y \
  curl \
  udisks2

if [[ "${REMOVE_DOCKER}" == "true" ]] || ! command -v docker >/dev/null 2>&1; then
  log "Docker kurulumu öncesi 3 saniye bekleniyor..."
  sleep 3

  log "DNS/network kontrolü başlıyor (max 10 deneme, 3 sn aralık)..."
  attempt=1
  max_attempts=10

  while (( attempt <= max_attempts )); do
    if ping -c1 -W1 8.8.8.8 >/dev/null 2>&1; then
      log "Network/DNS hazır görünüyor (deneme ${attempt}/${max_attempts})"
      break
    fi
    warn "Network/DNS henüz hazır değil (deneme ${attempt}/${max_attempts})"
    attempt=$((attempt+1))
    sleep 3
  done

  if (( attempt > max_attempts )); then
    err "DNS hala hazır değil, Docker kurulumu iptal edildi!"
  fi

  log "Docker kuruluyor (get.docker.com)..."
  curl -fsSL https://get.docker.com | sh
else
  log "Docker zaten kurulu ve REMOVE_DOCKER=false, docker kurulum adımı atlanıyor."
fi

log "OS Agent paketi indiriliyor: ${OS_AGENT_URL}"
curl -fL -o "${OS_AGENT_TMP}" "${OS_AGENT_URL}"

log "OS Agent dpkg -i ile kuruluyor..."
dpkg -i "${OS_AGENT_TMP}" || {
  warn "dpkg -i os-agent sırasında hata, apt -f install ile devam ediliyor..."
  apt -f install -y
}

log "homeassistant-supervised.deb indiriliyor (latest release)..."
curl -fL -o "${HA_SUP_TMP}" "${HA_SUP_URL}"

log "homeassistant-supervised.deb Debian 12 kontrolü için patch'leniyor..."
rm -rf "${PATCH_DIR}"
mkdir -p "${PATCH_DIR}"

dpkg-deb -x "${HA_SUP_TMP}" "${PATCH_DIR}"
dpkg-deb -e "${HA_SUP_TMP}" "${PATCH_DIR}/DEBIAN"

if [[ -f "${PATCH_DIR}/DEBIAN/preinst" ]]; then
  log "preinst script bulundu, exit 1 patch uygulanıyor..."
  cp "${PATCH_DIR}/DEBIAN/preinst" "${PATCH_DIR}/DEBIAN/preinst.original" || true
  sed -i 's/exit 1/true/g' "${PATCH_DIR}/DEBIAN/preinst"
else
  warn "preinst scripti bulunamadı; Debian 12 OS kontrolü patch edilemedi. Orijinal paket kurulacak ve hata verebilir."
  cp "${HA_SUP_TMP}" "${PATCHED_DEB}"
fi

if [[ -d "${PATCH_DIR}/DEBIAN" ]]; then
  dpkg-deb -b "${PATCH_DIR}" "${PATCHED_DEB}"
fi

log "Debconf ayarları qemuarm-64 olarak ayarlanıyor..."
echo "homeassistant-supervised ha/machine-type select qemuarm-64" | debconf-set-selections
echo "homeassistant-supervised ha/machine-type seen true" | debconf-set-selections

log "Home Assistant Supervised (patched) kuruluyor..."
apt install -y "${PATCHED_DEB}"

#----------------------------------------
# BİTİŞ
#----------------------------------------
log "Tüm adımlar tamamlandı."

echo
echo "Home Assistant Supervisor yeniden kurulduysa, arayüz genelde şu adresten açılır:"
echo "  http://<cihaz-ip-adresi>:8123/"
echo
echo "İlk açılışta 'Preparing Home Assistant' ekranı 10-20 dakika sürebilir."
echo "Supervisor loglarını izlemek için: docker logs -f hassio_supervisor"
echo
echo "Önerilen son adım: reboot"
echo "  sudo reboot"
echo
echo "Zip ve kernel paketleri burada duruyor:"
echo "  ${DOC_DIR}"
