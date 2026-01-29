#!/bin/bash

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

clear
echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}   GERADOR DE TUNNEL REVERSO (SSLH + DISFARCE)      ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo ""

# 1. VERIFICACAO DE ROOT
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERRO] Este script precisa rodar como ROOT.${NC}"
   exit 1
fi

# 2. DETECCAO DE IP (FORCANDO IPV4)
# AQUI ESTA A CORRECAO: A flag -4 obriga a usar o protocolo antigo
echo -e "${YELLOW}[*] Detectando IP Publico (IPv4)...${NC}"
PUBLIC_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com)

if [[ -z "$PUBLIC_IP" ]]; then
    echo -e "${RED}[ERRO] Nao foi possivel detectar o IPv4. Verifique sua conexao.${NC}"
    exit 1
fi
echo -e "${GREEN}    -> IP Encontrado: $PUBLIC_IP${NC}"
echo ""

# 3. PERGUNTAS DE CONFIGURACAO (INTERATIVO)
echo -e "${YELLOW}[?] Qual porta EXTERNA voce quer usar para enganar o firewall?${NC}"
echo "    (Recomendado: 443 para parecer HTTPS ou 80 para HTTP)"
read -p "    Digite a porta [443]: " PORT_EXTERNA
PORT_EXTERNA=${PORT_EXTERNA:-443}

echo ""
echo -e "${YELLOW}[?] Qual porta o SSH do servidor vai escutar localmente?${NC}"
echo "    (Geralmente a 22, so mude se voce alterou a config do SSH)"
read -p "    Digite a porta [22]: " PORT_SSH
PORT_SSH=${PORT_SSH:-22}

echo ""
echo -e "${YELLOW}[*] O script vai usar a porta 8080 interna para o site falso (Apache).${NC}"
PORT_HTTP=8080

echo ""
echo -e "${BLUE}>>> Configurando: Externa $PORT_EXTERNA -> (SSH $PORT_SSH | HTTP $PORT_HTTP)${NC}"
echo "Pressione ENTER para iniciar a instalacao..."
read

# 4. INSTALACAO DE PACOTES
echo -e "${YELLOW}[*] Atualizando e instalando dependencias...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq sslh apache2 net-tools curl openssh-server

# 5. CONFIGURACAO DO APACHE (DISFARCE)
echo -e "${YELLOW}[*] Configurando Apache para escutar apenas internamente...${NC}"
# Força o Apache a ouvir apenas no localhost na porta definida
echo "Listen 127.0.0.1:$PORT_HTTP" > /etc/apache2/ports.conf
# Cria pagina fake
echo "<!DOCTYPE html><html><head><title>Access Denied</title></head><body><h1>Service Unavailable</h1><p>The requested service is temporarily unavailable.</p></body></html>" > /var/www/html/index.html
systemctl restart apache2

# 6. CONFIGURACAO DO SSLH
echo -e "${YELLOW}[*] Configurando SSLH (Multiplexador)...${NC}"
# Configura o arquivo padrao do Debian/Ubuntu
cat > /etc/default/sslh <<EOF
RUN=yes
DAEMON=/usr/sbin/sslh
DAEMON_OPTS="--user sslh --listen 0.0.0.0:$PORT_EXTERNA --ssh 127.0.0.1:$PORT_SSH --http 127.0.0.1:$PORT_HTTP --pidfile /var/run/sslh/sslh.pid"
EOF

systemctl stop sslh
systemctl start sslh

# 7. CONFIGURACAO DO SSHD (GATEWAY PORTS)
echo -e "${YELLOW}[*] Ajustando SSHD para permitir tunelamento reverso externo...${NC}"
if ! grep -q "GatewayPorts yes" /etc/ssh/sshd_config; then
    echo "GatewayPorts yes" >> /etc/ssh/sshd_config
    systemctl restart ssh
fi

# 8. GERACAO DO SCRIPT CLIENTE (.BAT)
CLIENT_FILE="instalador_intranet.bat"
echo -e "${YELLOW}[*] Gerando script Windows: $CLIENT_FILE ...${NC}"

cat <<EOF > $CLIENT_FILE
@echo off
setlocal
:: --- GARANTIR COMPATIBILIDADE COM ACENTOS E ESPAÇOS ---
chcp 1252 >nul
:: ------------------------------------------------------

title INSTALADOR TUNNEL REVERSO - $PUBLIC_IP
color 1f

:: --- CONFIGURACOES DO SERVIDOR (GERADO AUTOMATICAMENTE) ---
set SERVER_IP=$PUBLIC_IP
set PORT=$PORT_EXTERNA
set USER=root
:: ----------------------------------------------------------

echo ========================================================
echo      CONFIGURANDO CONEXAO COM O SERVIDOR
echo      IP: %SERVER_IP%   |   PORTA: %PORT%
echo ========================================================
echo.

:: 1. CRIA CHAVES SSH
if not exist "%USERPROFILE%\.ssh" mkdir "%USERPROFILE%\.ssh"
if not exist "%USERPROFILE%\.ssh\id_rsa" (
    echo [1/4] Gerando identidade unica...
    ssh-keygen -t rsa -b 4096 -f "%USERPROFILE%\.ssh\id_rsa" -N "" -q
) else (
    echo [1/4] Identidade ja existe.
)

:: 2. ENVIA CHAVE PARA O SERVIDOR
echo.
echo [2/4] AUTORIZANDO NO SERVIDOR...
echo --------------------------------------------------------
echo ATENCAO: Digite a senha do servidor (ROOT) agora.
echo Isso sera feito apenas UMA VEZ para autorizar a maquina.
echo --------------------------------------------------------
echo.
type "%USERPROFILE%\.ssh\id_rsa.pub" | ssh -p %PORT% -o StrictHostKeyChecking=no %USER%@%SERVER_IP% "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

if %errorlevel% neq 0 (
    echo.
    echo [ERRO] Senha incorreta ou falha na conexao.
    pause
    exit
)

:: 3. CRIA O LOOP DE CONEXAO
echo.
echo [3/4] Criando script de persistencia...
(
echo @echo off
echo :loop
echo echo [%date% %time%] Conectando Tunnel...
:: Tunnel Reverso na porta 1080 (SOCKS) e redirecionamento
echo ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -p %PORT% -N -R 1080 %USER%@%SERVER_IP%
echo timeout /t 5
echo goto loop
) > "%USERPROFILE%\.ssh\tunnel_loop.bat"

:: 4. CONFIGURA INICIALIZACAO AUTOMATICA (VBS INVISIVEL)
echo [4/4] Configurando inicializacao do Windows...
set "STARTUP_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"

(
echo Set WshShell = CreateObject^("WScript.Shell"^)
echo WshShell.Run chr^(34^) ^& "%USERPROFILE%\.ssh\tunnel_loop.bat" ^& chr^(34^), 0
echo Set WshShell = Nothing
) > "%STARTUP_DIR%\IniciarTunnel.vbs"

:: INICIA AGORA
start "" "%STARTUP_DIR%\IniciarTunnel.vbs"

echo.
echo ========================================================
echo              INSTALACAO CONCLUIDA
echo ========================================================
echo O tunnel esta rodando em segundo plano.
echo Pode fechar esta janela.
pause
EOF

# 9. RELATORIO FINAL
echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}   SERVIDOR CONFIGURADO COM SUCESSO!      ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "1. SSLH rodando na porta: ${BLUE}$PORT_EXTERNA${NC}"
echo -e "2. Apache (Fake) escondido na porta: ${BLUE}$PORT_HTTP${NC}"
echo -e "3. SSH original na porta: ${BLUE}$PORT_SSH${NC}"
echo ""
echo -e "${YELLOW}>>> O ARQUIVO PARA O WINDOWS FOI GERADO:${NC}"
echo -e "${BLUE}$PWD/$CLIENT_FILE${NC}"
echo ""
echo "Copie o conteudo abaixo e salve no Bloco de Notas do Windows:"
echo "-------------------------------------------------------------"
cat $CLIENT_FILE
echo "-------------------------------------------------------------"
