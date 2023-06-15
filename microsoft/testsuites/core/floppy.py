# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

from assertpy import assert_that

from lisa import (
    RemoteNode,
    TestCaseMetadata,
    TestSuite,
    TestSuiteMetadata,
    SkippedException,
)
from lisa.tools import Modprobe
from lisa.operating_system import CentOs


@TestSuiteMetadata(
    area="core",
    category="functional",
    description="""
    This test suite ensures the floppy driver is disabled.
    The floppy driver is not needed on Azure and
    is known to cause problems in some scenarios.
    """,
)
class Floppy(TestSuite):
    @TestCaseMetadata(
        description="""
        The goal of this test is to ensure the floppy module is not enabled
        for images used on the Azure platform.
        This test case will
        1. Dry-run modprobe to see if floppy module can be loaded
        2. If "insmod" would be executed then the module is not already loaded
        3. If module cannot be found then it is not loaded
        If the module is loaded, running modprobe will have no output
        """,
        priority=1,
    )
    def check_floppy_module(self, node: RemoteNode) -> None:
        os_version = node.os.information.version
        is_centos = isinstance(node.os, CentOs)
        if is_centos and os_version < "7.8.0":
            raise SkippedException(
                "CentOS < 7.7 are not receiving fixes for this issue."
            )
        modprobe = node.tools[Modprobe]

        assert_that(modprobe.is_module_loaded("floppy")).described_as(
            "The floppy module should not be loaded. "
            "Try adding the module to the blacklist."
        ).is_false()
