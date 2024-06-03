ARG DRIVER_TOOLKIT_IMAGE="quay.io/ai-lab/nvidia-builder:latest"
ARG BASEIMAGE="quay.io/centos-bootc/centos-bootc:stream9"

FROM ${DRIVER_TOOLKIT_IMAGE} as builder

ARG BASE_URL='https://us.download.nvidia.com/tesla'

ARG OS_VERSION_MAJOR=''
ARG KERNEL_VERSION=''

ARG BUILD_ARCH=''
ARG TARGET_ARCH=''

ARG DRIVER_VERSION='550.54.15'

USER builder

WORKDIR /home/builder
COPY --chown=1001:0 x509-configuration.ini x509-configuration.ini

# Include growfs service
COPY build/usr /usr

RUN if [ "${KERNEL_VERSION}" == "" ]; then \
        NEWER_KERNEL_CORE=$(dnf info kernel-core | awk -F: '/^Source/{gsub(/.src.rpm/, "", $2); print $2}' | sort -n | tail -n1) \
        && RELEASE=$(dnf info ${NEWER_KERNEL_CORE} | awk -F: '/^Release/{print $2}' | tr -d '[:blank:]') \
        && VERSION=$(dnf info ${NEWER_KERNEL_CORE} | awk -F: '/^Version/{print $2}' | tr -d '[:blank:]') \
        && export KERNEL_VERSION="${VERSION}-${RELEASE}" ;\
    fi \
    && if [ "${OS_VERSION_MAJOR}" == "" ]; then \
        . /etc/os-release \
	&& export OS_ID="$(echo ${ID})" \
        && export OS_VERSION_MAJOR="$(echo ${VERSION} | cut -d'.' -f 1)" ;\
       fi \
    && if [ "${BUILD_ARCH}" == "" ]; then \
        export BUILD_ARCH=$(arch) \
        && export TARGET_ARCH=$(echo "${BUILD_ARCH}" | sed 's/+64k//') ;\
        fi \
    && export KVER=$(echo ${KERNEL_VERSION} | cut -d '-' -f 1) \
    && KREL=$(echo ${KERNEL_VERSION} | cut -d '-' -f 2 | sed 's/\.el._*.*\..\+$//' | cut -d'.' -f 1) \
    && if [ "${OS_ID}" == "rhel" ]; then \
		KDIST="."$(echo ${KERNEL_VERSION} | cut -d '-' -f 2 | cut -d '.' -f 2-) ;\
	else \
		KDIST="."$(echo ${KERNEL_VERSION} | cut -d '-' -f 2 | sed 's/^.*\(\.el._*.*\)\..\+$/\1/' | cut -d'.' -f 2) ;\
	fi \
    && DRIVER_STREAM=$(echo ${DRIVER_VERSION} | cut -d '.' -f 1) \
    && git clone --depth 1 --single-branch -b rhel${OS_VERSION_MAJOR} https://github.com/NVIDIA/yum-packaging-precompiled-kmod \
    && cd yum-packaging-precompiled-kmod \
    && mkdir BUILD BUILDROOT RPMS SRPMS SOURCES SPECS \
    && mkdir nvidia-kmod-${DRIVER_VERSION}-${BUILD_ARCH} \
    && curl -sLOf ${BASE_URL}/${DRIVER_VERSION}/NVIDIA-Linux-${TARGET_ARCH}-${DRIVER_VERSION}.run \
    && sh ./NVIDIA-Linux-${TARGET_ARCH}-${DRIVER_VERSION}.run --extract-only --target tmp \
    && mv tmp/kernel-open nvidia-kmod-${DRIVER_VERSION}-${BUILD_ARCH}/kernel \
    && tar -cJf SOURCES/nvidia-kmod-${DRIVER_VERSION}-${BUILD_ARCH}.tar.xz nvidia-kmod-${DRIVER_VERSION}-${BUILD_ARCH} \
    && mv kmod-nvidia.spec SPECS/ \
    && openssl req -x509 -new -nodes -utf8 -sha256 -days 36500 -batch \
      -config ${HOME}/x509-configuration.ini \
      -outform DER -out SOURCES/public_key.der \
      -keyout SOURCES/private_key.priv \
    && rpmbuild \
        --define "% _arch ${BUILD_ARCH}" \
        --define "%_topdir $(pwd)" \
        --define "debug_package %{nil}" \
        --define "kernel ${KVER}" \
        --define "kernel_release ${KREL}" \
        --define "kernel_dist ${KDIST}" \
        --define "driver ${DRIVER_VERSION}" \
        --define "driver_branch ${DRIVER_STREAM}" \
        -v -bb SPECS/kmod-nvidia.spec

FROM ${BASEIMAGE}

ARG BASE_URL='https://us.download.nvidia.com/tesla'

ARG OS_VERSION_MAJOR=''
ARG KERNEL_VERSION=''


ARG DRIVER_TYPE=passthrough
ENV NVIDIA_DRIVER_TYPE=${DRIVER_TYPE}

ARG DRIVER_VERSION='550.54.15'
ENV NVIDIA_DRIVER_VERSION=${DRIVER_VERSION}
ARG CUDA_VERSION='12.3.2'

ARG TARGET_ARCH=''
ENV TARGETARCH=${TARGET_ARCH}

ARG EXTRA_RPM_PACKAGES=''

# Disable vGPU version compatibility check by default
ARG DISABLE_VGPU_VERSION_CHECK=true
ENV DISABLE_VGPU_VERSION_CHECK=$DISABLE_VGPU_VERSION_CHECK

USER root

COPY --from=builder /home/builder/yum-packaging-precompiled-kmod/RPMS/*/*.rpm /rpms/
COPY --from=builder --chmod=444 /home/builder/yum-packaging-precompiled-kmod/tmp/firmware/*.bin /lib/firmware/nvidia/${DRIVER_VERSION}/

RUN dnf install -y /rpms/kmod-nvidia-*.rpm

COPY nvidia-toolkit-firstboot.service /usr/lib/systemd/system/nvidia-toolkit-firstboot.service

RUN if [ "${TARGET_ARCH}" == "" ]; then \
        export TARGET_ARCH="$(arch)" ;\
        fi \
    && if [ "${OS_VERSION_MAJOR}" == "" ]; then \
        . /etc/os-release \
        && export OS_VERSION_MAJOR="$(echo ${VERSION} | cut -d'.' -f 1)" ;\
       fi \
    && export DRIVER_STREAM=$(echo ${DRIVER_VERSION} | cut -d '.' -f 1) \
        CUDA_VERSION_ARRAY=(${CUDA_VERSION//./ }) \
        CUDA_DASHED_VERSION=${CUDA_VERSION_ARRAY[0]}-${CUDA_VERSION_ARRAY[1]} \
        CUDA_REPO_ARCH=${TARGET_ARCH} \
    && if [ "${TARGET_ARCH}" == "aarch64" ]; then CUDA_REPO_ARCH="sbsa"; fi \
    && dnf config-manager --best --nodocs --setopt=install_weak_deps=False --save \
    && dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel${OS_VERSION_MAJOR}/${CUDA_REPO_ARCH}/cuda-rhel${OS_VERSION_MAJOR}.repo \
    && dnf -y module enable nvidia-driver:${DRIVER_STREAM}/default \
    && dnf install -y \
        nvidia-driver-cuda-${DRIVER_VERSION} \
        nvidia-driver-libs-${DRIVER_VERSION} \
        nvidia-driver-NVML-${DRIVER_VERSION} \
        cuda-compat-${CUDA_DASHED_VERSION} \
        cuda-cudart-${CUDA_DASHED_VERSION} \
        nvidia-persistenced-${DRIVER_VERSION} \
        nvidia-container-toolkit \
        ${EXTRA_RPM_PACKAGES} \
    && if [ "$DRIVER_TYPE" != "vgpu" ] && [ "$TARGET_ARCH" != "arm64" ]; then \
        versionArray=(${DRIVER_VERSION//./ }); \
        DRIVER_BRANCH=${versionArray[0]}; \
        dnf module enable -y nvidia-driver:${DRIVER_BRANCH} && \
        dnf install -y nvidia-fabric-manager-${DRIVER_VERSION} libnvidia-nscq-${DRIVER_BRANCH}-${DRIVER_VERSION} ; \
    fi \
    && dnf clean all \
    && ln -s /usr/lib/systemd/system/nvidia-toolkit-firstboot.service /usr/lib/systemd/system/basic.target.wants/nvidia-toolkit-firstboot.service \
    && echo "blacklist nouveau" > /etc/modprobe.d/blacklist_nouveau.conf


ARG SSHPUBKEY

# The --build-arg "SSHPUBKEY=$(cat ~/.ssh/id_rsa.pub)" option inserts your
# public key into the image, allowing root access via ssh.
RUN set -eu; mkdir -p /usr/ssh && \
    echo 'AuthorizedKeysFile /usr/ssh/%u.keys .ssh/authorized_keys .ssh/authorized_keys2' >> /etc/ssh/sshd_config.d/30-auth-system.conf && \
    echo ${SSHPUBKEY} > /usr/ssh/root.keys && chmod 0600 /usr/ssh/root.keys

# Setup /usr/lib/containers/storage as an additional store for images.
# Remove once the base images have this set by default.
# Also make sure not to duplicate if a base image already has it specified.
RUN grep -q /usr/lib/containers/storage /etc/containers/storage.conf || \
    sed -i -e '/additionalimage.*/a "/usr/lib/containers/storage",' \
        /etc/containers/storage.conf && \
	cp /run/.input/ilab* /usr/local/bin/


ARG INSTRUCTLAB_IMAGE
ARG INSTRUCTLAB_IMAGE_ID
ARG VLLM_IMAGE
ARG VLLM_IMAGE_ID
ARG TRAIN_IMAGE
ARG TRAIN_IMAGE_ID
ARG GPU_COUNT_COMMAND="nvidia-ctk --quiet cdi list | grep -P nvidia.com/gpu='\\\\d+' | wc -l"

RUN for i in /usr/local/bin/ilab*; do \
	sed -i 's/__REPLACE_TRAIN_DEVICE__/cuda/' $i;  \
	sed -i 's/__REPLACE_CONTAINER_DEVICE__/nvidia.com\/gpu=all/' $i; \
	sed -i "s%__REPLACE_IMAGE_NAME__%${INSTRUCTLAB_IMAGE}%" $i; \
	sed -i "s%__REPLACE_VLLM_NAME__%${VLLM_IMAGE}%" $i; \
	sed -i "s%__REPLACE_TRAIN_NAME__%${TRAIN_IMAGE}%" $i; \
	sed -i 's%__REPLACE_ENDPOINT_URL__%http://0.0.0.0:8080/v1%' $i; \
	sed -i "s%__REPLACE_GPU_COUNT_COMMAND__%${GPU_COUNT_COMMAND}%" $i; \
	sed -i 's/__REPLACE_TRAIN_DEVICE__/cuda/' $i; \
    done

# Added for running as an OCI Container to prevent Overlay on Overlay issues.
VOLUME /var/lib/containers

#RUN IID=$(podman --root /usr/lib/containers/storage pull oci:/run/.input/vllm) && \
#    podman --root /usr/lib/containers/storage image tag ${IID} ${VLLM_IMAGE}
#RUN IID=$(podman --root /usr/lib/containers/storage pull oci:/run/.input/instructlab-nvidia) && \
#    podman --root /usr/lib/containers/storage image tag ${IID} ${INSTRUCTLAB_IMAGE}
#RUN IID=$(podman --root /usr/lib/containers/storage pull oci:/run/.input/deepspeed-trainer) && \
#    podman --root /usr/lib/containers/storage image tag ${IID} ${TRAIN_IMAGE}	
#RUN podman system reset --force 2>/dev/null
