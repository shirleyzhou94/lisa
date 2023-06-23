#!/bin/bash
########################################################################
#
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
#
########################################################################
########################################################################
#
# Description:
#   This script installs nVidia GPU drivers.
#   nVidia CUDA and GRID drivers are supported.
#   Refer to the below link for supported releases:
#   https://docs.microsoft.com/en-us/azure/virtual-machines/linux/n-series-driver-setup
#
# Steps:
#   1. Install dependencies
#   2. Compile and install GPU drivers based on the driver type.
#       The driver type is injected in the constants.sh file, in this format:
#       driver="CUDA" or driver="GRID"
#
#   Please check the below URL for any new versions of the GRID driver:
#   https://docs.microsoft.com/en-us/azure/virtual-machines/linux/n-series-driver-setup
#
########################################################################

grid_driver="https://go.microsoft.com/fwlink/?linkid=874272"

#######################################################################
function skip_test() {
	GetOSVersion
	LogMsg "Checking Distro version... DISTRO: $DISTRO VERSION_ID:$VERSION_ID os_RELEASE:$os_RELEASE"
	if [[ $driver == "CUDA" ]] && ([[ $DISTRO == *"suse"* ]] || [[ $DISTRO == "redhat_8" ]] || [[ $DISTRO == *"debian"* ]] || [[ $DISTRO == "almalinux_8" ]] || [[ $DISTRO == "rockylinux_8" ]]); then
		LogMsg "$DISTRO not supported. Skip the test."
		SetTestStateSkipped
		exit 0
	fi

	if [[ $driver == "AMD" ]]; then
		LogMsg "AMD GPU test not supported. Skip the test."
		SetTestStateSkipped
		exit 0
	fi

	# https://docs.microsoft.com/en-us/azure/virtual-machines/linux/n-series-driver-setup
	# Only support Ubuntu 16.04 LTS, 18.04 LTS, RHEL/CentOS 7.0 ~ 7.9, SLES 12 SP2
	# Azure HPC team defines GRID driver support scope.
	if [[ $driver == "GRID" ]]; then
		support_distro="redhat_7 centos_7 ubuntu_16.04 ubuntu_18.04 ubuntu_20.04 ubuntu_x suse_12"
		unsupport_flag=0
		GetDistro
		source /etc/os-release
		if [[ "$support_distro" == *"$DISTRO"* ]]; then
			if [[ $DISTRO == "redhat_7" ]]; then
				# RHEL 7.x > 7.9 should be skipped
				_minor_ver=$(echo $VERSION_ID | cut -d'.' -f 2)
				if [[ $_minor_ver -gt 9 ]]; then
					unsupport_flag=1
				fi
			fi
			# TODO: centos_8?
			if [[ $DISTRO == "centos_7" ]]; then
				# 7.x > 7.9 should be skipped
				_minor_ver=$(cat /etc/centos-release | cut -d ' ' -f 4 | cut -d '.' -f 2)
				if [[ $_minor_ver -gt 9 ]]; then
					unsupport_flag=1
				fi
			fi
			if [[ $DISTRO == "ubuntu"* ]]; then
				# skip other ubuntu version than 16.04, 18.04, 20.04, 21.04
				if [[ $os_RELEASE != "16.04" && $os_RELEASE != "18.04" && $os_RELEASE != "20.04" && $os_RELEASE != "21.04" ]]; then
					unsupport_flag=1
				fi
			fi
			if [[ $DISTRO == "suse_12" ]]; then
				# skip others except SLES 12 SP2 BYOS and SAP and SLES 15 SP2,
				# However, they use default-kernel and no repo to Azure customer.
				# This test will fail until SUSE enables azure-kernel for GRID driver installation
				if [ $VERSION_ID != "12.2" || $VERSION_ID != "15.2" ];then
					unsupport_flag=1
				fi
			fi
		else
			unsupport_flag=1
		fi
		if [ $unsupport_flag = 1 ]; then
			LogErr "$DISTRO not supported. Skip the test."
			SetTestStateSkipped
			exit 0
		fi
	fi
}

function InstallCUDADrivers() {
	LogMsg "Starting CUDA driver installation"
	case $DISTRO in
	redhat_7|centos_7)
		CUDA_REPO_PKG="cuda-repo-rhel7-${CUDADriverVersion}.x86_64.rpm"
		LogMsg "Using ${CUDA_REPO_PKG}"

		wget http://developer.download.nvidia.com/compute/cuda/repos/rhel7/x86_64/"${CUDA_REPO_PKG}" -O /tmp/"${CUDA_REPO_PKG}"
		if [ $? -ne 0 ]; then
			LogErr "Failed to download ${CUDA_REPO_PKG}"
			SetTestStateAborted
			return 1
		else
			LogMsg "Successfully downloaded the ${CUDA_REPO_PKG} file in /tmp directory"
		fi

		rpm -ivh /tmp/"${CUDA_REPO_PKG}"
		LogMsg "Installed the rpm package, ${CUDA_REPO_PKG}"

		# For RHEL/CentOS, it might be needed to install vulkan-filesystem to install CUDA drivers.
		# Download and Install vulkan-filesystem
		wget http://mirror.centos.org/centos/7/os/x86_64/Packages/vulkan-filesystem-1.1.97.0-1.el7.noarch.rpm -O /tmp/vulkan-filesystem-1.1.97.0-1.el7.noarch.rpm
		if [ $? -ne 0 ]; then
			LogErr "Failed to download vulkan-filesystem rpm"
			SetTestStateAborted
			return 1
		else
			LogMsg "Successfully downloaded the vulkan-filesystem rpm file in /tmp directory"
		fi
		yum -y install /tmp/vulkan-filesystem-1.1.97.0-1.el7.noarch.rpm

		yum --nogpgcheck -y install cuda-drivers > $HOME/install_drivers.log 2>&1
		if [ $? -ne 0 ]; then
			LogErr "Failed to install the cuda-drivers!"
			SetTestStateAborted
			return 1
		else
			LogMsg "Successfully installed cuda-drivers"
		fi
	;;

	ubuntu*)
		GetOSVersion
		# 20.04 version install differs from older versions. Special case the new version. Abort if version doesn't exist yet.
		if [[ $os_RELEASE =~ 21.* ]] || [[ $os_RELEASE =~ 22.* ]]; then
			LogErr "CUDA Driver may not exist for Ubuntu > 21.XX , check https://developer.download.nvidia.com/compute/cuda/repos/ for new versions."
			SetTestStateAborted;
		fi
		if [ $os_RELEASE = 20.04 ]; then
			LogMsg "Proceeding with installation for 20.04"
			wget -O /etc/apt/preferences.d/cuda-repository-pin-600 https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64/cuda-ubuntu2004.pin
			apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64/3bf863cc.pub
			add-apt-repository "deb http://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64/ /"
		else
			if [[ $os_RELEASE =~ 19.* ]]; then
				LogMsg "There is no cuda driver for $os_RELEASE, used the one for 18.10"
				os_RELEASE="18.10"
			fi
			CUDA_REPO_PKG="cuda-repo-ubuntu${os_RELEASE//./}_${CUDADriverVersion}_amd64.deb"
			LogMsg "Using ${CUDA_REPO_PKG}"

			wget http://developer.download.nvidia.com/compute/cuda/repos/ubuntu"${os_RELEASE//./}"/x86_64/"${CUDA_REPO_PKG}" -O /tmp/"${CUDA_REPO_PKG}"
			if [ $? -ne 0 ]; then
				LogErr "Failed to download ${CUDA_REPO_PKG}"
				SetTestStateAborted
				return 1
			else
				LogMsg "Successfully downloaded ${CUDA_REPO_PKG}"
			fi
		fi

		apt-key adv --fetch-keys http://developer.download.nvidia.com/compute/cuda/repos/ubuntu"${os_RELEASE//./}"/x86_64/3bf863cc.pub
		if [ $os_RELEASE != 20.04 ]; then
			dpkg -i /tmp/"${CUDA_REPO_PKG}"
			LogMsg "Installed ${CUDA_REPO_PKG}"
			dpkg_configure
		fi
		apt-get update

		# Issue: latest Nvidia Driver version 510 is broken on T4 VM, roll back to older version if needed
		if [ -z ${NVIDIAVersion+x} ]; then
			LogMsg "Using latest cuda-drivers"
			apt -y --allow-unauthenticated install cuda-drivers > $HOME/install_drivers.log 2>&1
		else
			LogMsg "Using cuda-drivers-$NVIDIAVersion"
			apt -y --allow-unauthenticated install cuda-drivers-$NVIDIAVersion  > $HOME/install_drivers.log 2>&1
		fi

		if [ $? -ne 0 ]; then
			LogErr "Failed to install cuda-drivers package!"
			SetTestStateAborted
			return 1
		else
			LogMsg "Successfully installed cuda-drivers package"
		fi
	;;
	esac

	find /var/lib/dkms/nvidia* -name make.log -exec cp {} $HOME/nvidia_dkms_make.log \;
	if [[ ! -f "$HOME/nvidia_dkms_make.log" ]]; then
		echo "File not found, make.log" > $HOME/nvidia_dkms_make.log
	fi
}

function InstallGRIDdrivers() {
	LogMsg "Starting GRID driver installation"
	wget "$grid_driver" -O /tmp/NVIDIA-Linux-x86_64-grid.run
	if [ $? -ne 0 ]; then
		LogErr "Failed to download the GRID driver!"
		SetTestStateAborted
		return 1
	else
		LogMsg "Successfully downloaded the GRID driver"
	fi

	cat > /etc/modprobe.d/nouveau.conf<< EOF
	blacklist nouveau
	blacklist lbm-nouveau
EOF
	LogMsg "Updated nouveau.conf file with blacklist"

	pushd /tmp
	chmod +x NVIDIA-Linux-x86_64-grid.run
	./NVIDIA-Linux-x86_64-grid.run --no-nouveau-check --silent --no-cc-version-check
	if [ $? -ne 0 ]; then
		LogMsg "Failed to install the GRID driver: $?"
		LogErr "Failed to install the GRID driver!"
		SetTestStateAborted
		return 1
	else
		LogMsg "Successfully install the GRID driver"
	fi
	popd

	cp /etc/nvidia/gridd.conf.template /etc/nvidia/gridd.conf
	echo 'IgnoreSP=FALSE' >> /etc/nvidia/gridd.conf
	LogMsg "Added IgnoreSP parameter in gridd.conf"
	find /var/log/* -name nvidia-installer.log -exec cp {} $HOME/nvidia-installer.log \;
	if [[ ! -f "$HOME/nvidia-installer.log" ]]; then
		echo "File not found, nvidia-installer.log" > $HOME/nvidia-installer.log
	fi
}

function install_gpu_requirements() {
	apt-get update --fix-missing -y
	install_package "wget lshw gcc make"
	LogMsg "installed wget lshw gcc make"

	case $DISTRO in
		redhat_7|centos_7|redhat_8|almalinux_8|rockylinux_8)
			if [[ $DISTRO == "centos_7" ]]; then
				# for all releases that are moved into vault.centos.org
				# we have to update the repositories first
				yum -y install centos-release
				if [ $? -eq 0 ]; then
					LogMsg "Successfully installed centos-release"
				else
					LogErr "Failed to install centos-release"
					SetTestStateAborted
					return 1
				fi
				yum clean all
				yum -y install --enablerepo=C*-base --enablerepo=C*-updates kernel-devel-"$(uname -r)" kernel-headers-"$(uname -r)"
				if [ $? -eq 0 ]; then
					LogMsg "Successfully installed kernel-devel package with its header"
				else
					LogErr "Failed to install kernel-devel package with its header"
					SetTestStateAborted
					return 1
				fi
			else
				yum -y install kernel-devel-"$(uname -r)" kernel-headers-"$(uname -r)"
				if [ $? -eq 0 ]; then
					LogMsg "Successfully installed kernel-devel package with its header"
				else
					LogErr "Failed to installed kernel-devel package with its header"
					SetTestStateAborted
					return 1
				fi
			fi

			# Kernel devel package is mandatory for nvdia cuda driver installation.
			# Failure to install kernel devel should be treated as test aborted not failed.
			rpm -q --quiet kernel-devel-$(uname -r)
			if [ $? -ne 0 ]; then
				LogErr "Failed to install the RH/CentOS kernel-devel package"
				SetTestStateAborted
				return 1
			else
				LogMsg "Successfully rpm-ed kernel-devel packages"
			fi

			# mesa-libEGL install/update is require to avoid a conflict between
			# libraries - bugzilla.redhat 1584740
			yum -y install mesa-libGL mesa-libEGL libglvnd-devel
			if [ $? -eq 0 ]; then
				LogMsg "Successfully installed mesa-libGL mesa-libEGL libglvnd-devel"
			else
				LogErr "Failed to install mesa-libGL mesa-libEGL libglvnd-devel"
				SetTestStateAborted
				return 1
			fi

			install_epel
			yum --nogpgcheck -y install dkms
			if [ $? -eq 0 ]; then
				LogMsg "Successfully installed dkms"
			else
				LogErr "Failed to install dkms"
				SetTestStateAborted
				return 1
			fi
		;;

		ubuntu*)
			# apt -y install build-essential libelf-dev linux-tools-"$(uname -r)" linux-cloud-tools-"$(uname -r)" python libglvnd-dev ubuntu-desktop
			# E: Unable to locate package libglvnd-dev
			LogMsg "Installing required packages for nvidia gpu driver..."
			# libmlx4-1 has no installation candidate ubuntu2004
			# install_package "libdapl2 libmlx4-1" 
			# req_pkg="build-essential libelf-dev linux-tools-"$(uname -r)" linux-cloud-tools-"$(uname -r)" python ubuntu-desktop"
			# ubuntu-desktop seems to cause timeout
			req_pkg="build-essential libelf-dev linux-tools-"$(uname -r)" linux-cloud-tools-"$(uname -r)" python"
			install_package $req_pkg
			# apt --fix-broken install -y
			# apt-get install -y build-essential libelf-dev linux-tools-"$(uname -r)" linux-cloud-tools-"$(uname -r)" python ubuntu-desktop
			if [ $? -eq 0 ]; then
				LogMsg "Successfully installed $req_pkg"
			else
				LogErr "Failed to install $req_pkg"
				SetTestStateAborted
				return 1
			fi
		;;

		suse_15*)
			kernel=$(uname -r)
			if [[ "${kernel}" == *azure ]]; then
				zypper install --oldpackage -y kernel-azure-devel="${kernel::-6}"
				if [ $? -eq 0 ]; then
					LogMsg "Successfully installed kernel-azure-devel"
				else
					LogErr "Failed to install kernel-azure-devel"
					SetTestStateAborted
					return 1
				fi
				zypper install -y kernel-devel-azure xorg-x11-driver-video libglvnd-devel
				if [ $? -eq 0 ]; then
					LogMsg "Successfully installed kernel-azure-devel xorg-x11-driver-video libglvnd-devel"
				else
					LogErr "Failed to install kernel-azure-devel xorg-x11-driver-video libglvnd-devel"
					SetTestStateAborted
					return 1
				fi
			else
				zypper install -y kernel-default-devel xorg-x11-driver-video libglvnd-devel
				if [ $? -eq 0 ]; then
					LogMsg "Successfully installed kernel-default-devel xorg-x11-driver-video libglvnd-devel"
				else
					LogErr "Failed to install kernel-default-devel xorg-x11-driver-video libglvnd-devel"
					SetTestStateAborted
					return 1
				fi
			fi
		;;
	esac
}

#######################################################################
#
# Main script body
#
#######################################################################
# Source utils.sh
. utils.sh || {
	echo "ERROR: unable to source utils.sh!"
	echo "TestAborted" > state.txt
	exit 0
}
UtilsInit

GetDistro

# Validate repo availability
# GPCv1 uses Ubuntu 16.04 one of the package is not fetchable
# ubuntu 1804+  The repository 'http://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64  InRelease' is not signed.
# if [[ $DISTRO == "ubuntu_16.04" ]]; then
# 	LogMsg "Skip updating repos for ubuntu 16.04"
# else
# 	LogMsg "Updating repos"
# 	update_repos
# 	if [ $? != 0 ]; then
# 		LogErr "unable to update_repos, abort test."
# 		SetTestStateAborted
# 		exit 0
# 	fi
# fi

# Validate the distro version eligibility
LogMsg "Validate the distro version eligibility."
skip_test
_state=$(cat state.txt)
if [ $_state == "TestAborted" ]; then
	LogErr "Stop test procedure due to state $_state"
	exit 0
fi

# Install dependencies
install_gpu_requirements

if [ "$driver" == "CUDA" ]; then
	InstallCUDADrivers
elif [ "$driver" == "GRID" ]; then
	InstallGRIDdrivers
elif [ "$driver" == "AMD" ]; then
	LogMsg "AMD GPU not supported. Skipping. Test to be added."
else
	LogMsg "Driver type not detected, defaulting to CUDA driver."
	InstallCUDADrivers
fi

if [ $? -ne 0 ]; then
	LogErr "Could not install the $driver drivers!"
	SetTestStateFailed
	exit 0
fi

# Check and install lsvmbus
check_lsvmbus
SetTestStateCompleted
exit 0
