#!/bin/bash
####################################
#
# Nextcloud Install script.
#
####################################

# Check if user is root or sudo
if ! [ $( id -u ) = 0 ]; then
    echo -e "${RED}Please run the nextcloud script as sudo or root user. ${NC}"
    exit 1
fi


# Output colors
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' 

# Log Location
LOG="/tmp/nextcloud-install.log"


# Initialize variable values
NCdomainName=""
NCIP=""
mysqlRootPwd=$(openssl rand -base64 24)
NCDbName=nextcloud
NCAdmin=ncadmin
NCPass=$(openssl rand -base64 18)
DbUser=nextcloud_dbadmin
DbPwd=$(openssl rand -base64 24)
OS=$(lsb_release -i | cut -f 2-)
PHP=/etc/php/*/apache2/php.ini

#clean terminal
clear

echo -e "${YELLOW}Welcome to my Nextcloud install script.\nThe script will automatically setup:\n \n${BLUE} - SSL with a self sign certificate. \n - Enable memcache APCu local Caching.\n - Enable Redis for database transactional locking.\n - Setup Nextcloud PHP Recommendations.\n - Enable Pretty URl's.\n - Setup Cron for background tasks.\n - Enabling Bruteforce protection.\n ${NC}"
echo""

#Collect
read -p "Enter Nextcloud Server's hostname - e.g cloud.example.com: " NCdomainName
read -p "Enter your Server's IP Address: " NCIP

#change hostname
sudo hostnamectl set-hostname "${NCdomainName}"

#seed Mysql install values
debconf-set-selections <<< "mysql-server mysql-server/root_password password ${mysqlRootPwd}"
debconf-set-selections <<< "mysql-server mysql-server/root_password_again password ${mysqlRootPwd}"

#update OS
echo -e "${YELLOW}Updating your ${OS} OS.. ${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update -y && apt upgrade -y && apt dist-upgrade -y &>> ${LOG}
apt install -y wget &>> ${LOG}

#clear command line
clear

#download nextcloud
echo -e "${YELLOW}Downloading Nextcloud.. ${NC}"
wget https://download.nextcloud.com/server/releases/latest.zip
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to download nextcloud" 1>&2
    exit 1
fi
echo -e "${GREEN}Downloaded Nextcloud${NC}"

#install Mariadb
echo -e "${YELLOW}Installing Database ...${NC}"
sudo apt install mariadb-server -y &>> ${LOG}
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to install mariadb-server" 1>&2
    exit 1
fi 
echo -e "${GREEN}Downloaded MariaDB Server${NC}"


#secure mariadb
echo -e "${YELLOW}Securing your Database.. ${NC}"
echo > mysql_secure_installation.sql << EOF
UPDATE mysql.user SET Password=PASSWORD('${mysqlRootPwd}') WHERE User='root';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to secure database " 1>&2
    exit 1
fi
echo -e "${GREEN}Secured database successfully${NC}"

# Create database & user and set permissions
CODE="
DROP DATABASE IF EXISTS ${NCDbName};
CREATE DATABASE IF NOT EXISTS ${NCDbName};
CREATE USER IF NOT EXISTS '${DbUser}'@'localhost' IDENTIFIED BY \"${DbPwd}\";
GRANT ALL PRIVILEGES ON ${NCDbName}.* TO '${DbUser}'@'localhost';
FLUSH PRIVILEGES;"

# Execute SQL code
echo -e "${YELLOW}Creating and setting up your Nextcloud Database${NC}"
echo ${CODE} | mysql -u root -p${mysqlRootPwd}
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to create and setup Nextcloud database " 1>&2
    exit 1
fi
echo -e "${GREEN}Setting up Nextcloud database completed successfully${NC}"


#install required packages
echo -e "${YELLOW}Installing required Nextcloud packages in the background, this may take a while ..${NC}"
sudo apt install apache2 php php-apcu php-bcmath php-cli php-common php-curl php-gd php-gmp php-imagick php-intl php-mbstring php-mysql php-zip php-xml unzip php-imagick redis php-redis imagemagick cron -y > /dev/null 2>&1 &>> ${LOG}
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to install required package" 1>&2
    exit 1
fi
echo -e "${GREEN}Installing packages completed successfully${NC}"

#configure  php extensions
sudo phpenmod bcmath gmp imagick intl -y &>> ${LOG}
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to setup php extenions" 1>&2
    exit 1
fi
echo -e "${GREEN}PHP extensions setup successfully completed${NC}"

#Setup Nextcloud
echo -e "${YELLOW}Setting up Apache and Nextcloud files ..\n This may take some time..${NC}"
unzip latest.zip > /dev/null 2>&1

#Rename Nexcloud directory
mv nextcloud ${NCdomainName}

#set folder permissions
sudo chown -R www-data:www-data ${NCdomainName}

#Move Nextcloud folder to apache dir
sudo mv ${NCdomainName} /var/www

#Disable default apache site
sudo a2dissite 000-default.conf > /dev/null 2>&1 &>> ${LOG}

#create host config file
cat > /etc/apache2/sites-available/${NCdomainName}.conf << EOF
 <VirtualHost *:80>
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R=301,L]
</VirtualHost>
<VirtualHost *:443>
    DocumentRoot "/var/www/${NCdomainName}"

    Header add Strict-Transport-Security: "max-age=15552000;includeSubdomains"

    ServerAdmin admin@cloud.tt.com
    ServerName cloud.tt.com

    <Directory "/var/www/${NCdomainName}/">
    Options MultiViews FollowSymlinks
    AllowOverride All
    Order allow,deny
    Allow from all
    </Directory>

   TransferLog /var/log/apache2/${NCdomainName}.log
   ErrorLog /var/log/apache2/${NCdomainName}.log


    # Intermediate configuration
    SSLEngine               on
    SSLCompression          off
    SSLProtocol             -all +TLSv1.2 +TLSv1.3
    SSLCipherSuite          ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20>
    SSLHonorCipherOrder     off
    SSLSessionTickets       off
    ServerSignature         off

    SSLCertificateFile /etc/ssl/certs/ssl-cert-snakeoil.pem
    SSLCertificateKeyFile /etc/ssl/private/ssl-cert-snakeoil.key
</VirtualHost>
EOF

NCdataPath="/var/www/${NCdomainName}/data"

#enable site
sudo a2ensite ${NCdomainName}.conf > /dev/null 2>&1 &>> ${LOG}

#enable required php modules
sudo a2enmod dir env headers mime rewrite ssl > /dev/null 2>&1 &>> ${LOG}

# Install Nextcloud
echo -e "${YELLOW}Installing Nextcloud, it might take a while..."
cd /var/www/${NCdomainName}
sudo -u www-data php /var/www/"${NCdomainName}"/occ maintenance:install \
--data-dir="$NCdataPath" \
--database=mysql \
--database-name=$NCDbName \
--database-user="$DbUser" \
--database-pass="$DbPwd" \
--admin-user="$NCAdmin" \
--admin-pass="$NCPass"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to run maintenance install" 1>&2
    exit 1
fi
echo -e "${GREEN}Maintenance install successfully completed${NC}"

#create and setup nextcloud logging.
echo -e "${YELLOW}Setting Up Nextcloud Admin Logging .."
touch /var/log/nextcloud.log
chown www-data:www-data /var/log/nextcloud.log
sleep 2
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set log_type --value="file"
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set logfile --value="/var/log/nextcloud.log"
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set loglevel --value="2"
sudo -u www-data php /var/www/${NCdomainName}/occ app:enable admin_audit
sudo -u www-data php /var/www/${NCdomainName}/occ config:app:set admin_audit logfile --value="/var/log/nextcloud.log"
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set logfile_audit --value="/var/log/nextcloud.log"
#enable external share support and install php-smbclient
sudo -u www-data php /var/www/${NCdomainName}/occ app:enable files_external
if [[ "$OS" == "Ubuntu" ]]; then
    echo -e "${YELLOW}Installing PHP SMB Support for ${OS}" 1>&2
    sudo DEBIAN_FRONTEND=noninteractive apt install -y php-smbclient
elif [[ "$OS" == "Debian" ]]; then
    echo -e "${YELLOW}Installing PHP SMB Support for ${OS}" 1>&2
    sudo DEBIAN_FRONTEND=noninteractive apt install -y smbclient 
else
  echo -e "${RED}Could not determine OS skipping PHP SMB Install" 1>&2

fi

#Set nextcloud to use cron instead of Ajax
#sudo crontab -u www-data -l | { cat; echo "*/5  *  *  *  * php -f /var/www/${NCdomainName}/cron.php"; } | sudo crontab -u www-data - > /dev/null 2>&1
sudo crontab -u www-data -l | { cat; echo "*/5  *  *  *  * php -f /var/www/${NCdomainName}/cron.php > /dev/null 2>&1"; } | sudo crontab -u www-data -

#update cron
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set maintenance_window_start --value=“15”

#enable pretty url's
echo -e "${YELLOW}Enabling pretty url's. ${NC}"
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set htaccess.RewriteBase --value="/"
sudo -u www-data php /var/www/${NCdomainName}/occ maintenance:update:htaccess
#securing web ui from bruteforce
echo -e "${YELLOW}Enabling bruteforce protection.${NC}"
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set auth.bruteforce.protection.enabled --value="true"
#set truested domains
echo -e "${YELLOW}Enabling trusted domains.${NC}"
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set trusted_domains 0 --value="127.0.0.1"
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set trusted_domains 1 --value="${NCdomainName}"
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set trusted_domains 2 --value="${NCIP}"

#set php recommended Configurations
echo -e "${YELLOW}Enabling PHP Recommendations for Nextcloud.${NC}"
sudo sed -i "s:memory_limit = .*:memory_limit = 512M:" $PHP
sudo sed -i "s:upload_max_filesize = .*:upload_max_filesize = 200M:" $PHP
sudo sed -i "s:max_execution_time = .*:max_execution_time = 360:" $PHP
sudo sed -i "s:post_max_size = .*:post_max_size = 200M:" $PHP
sudo sed -i "s:;opcache.interned_strings_buffer=.*:opcache.interned_strings_buffer=16:" $PHP
sudo sed -i "s:;opcache.max_accelerated_files=.*:opcache.max_accelerated_files=10000:" $PHP
sudo sed -i "s:;opcache.memory_consumption=.*:opcache.memory_consumption=128:" $PHP
sudo sed -i "s:;opcache.save_comments=.*:opcache.save_comments=1:" $PHP
sudo sed -i "s:;opcache.revalidate_freq=.*:opcache.revalidate_freq=1:" $PHP
#add and fix for memcache local
sudo sed -i -e $'$a\\[nextcloud]' /etc/php/*/mods-available/apcu.ini
sudo sed -i -e $'$a\\apc.enable_cli = 1' /etc/php/*/mods-available/apcu.ini
sudo sed -i -e $'$a\\memory_limit = 512M' /etc/php/*/mods-available/apcu.ini

#setup Caching
echo -e "${YELLOW}Setting  Up Caching..${NC}"
sudo usermod -a -G redis www-data
sleep 5
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set filelocking.enabled --value="true"
sleep 5
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set memcache.local --value="\OC\Memcache\APCu"
sleep 5
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set memcache.locking --value="\OC\Memcache\Redis"
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set memcache.distributed --value="\OC\Memcache\Redis"
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set redis host --value="localhost"
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set redis port --value="6379"
sudo -u www-data php /var/www/${NCdomainName}/occ config:system:set redis timeout --value="0.0"

#configure theming
sudo -u www-data php /var/www/${NCdomainName}/occ theming:config name ${NCdomainName}
sudo -u www-data php /var/www/${NCdomainName}/occ theming:config url https://${NCdomainName}

#restart apache2
echo -e "${YELLOW}Restarting Apache service.${NC}"
sudo systemctl restart apache2 > /dev/null 2>&1 &>> ${LOG}
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to restart Apache service" 1>&2
    exit 1
fi
echo -e "${GREEN}Restarting Apache Service successfully completed${NC}"

#installtion clean up
echo -e "${YELLOW}Cleaning up installation temp files ....${NC}"
sudo rm -rf latest.zip 
sudo rm -rf mysql_secure_installation.sql
echo""


echo -e "${BLUE}Nextcloud installation and setup complete\n- Visit: https://${NCIP} or https://${NCdomainName}\n Admin username: ${NCAdmin}\n Admin password: ${NCPass}\n\n Database root user password: ${mysqlRootPwd} \n Database User: ${DbUser} \n Database user password: ${DbPwd}\n\n ${GREEN}Thank you for using my script and being part of the geek2gether community.${NC}"
