# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.


from typing import Optional, Type

from lisa.executable import Tool


class Ifconfig(Tool):
    @property
    def command(self) -> str:
        return "ifconfig"

    @classmethod
    def _freebsd_tool(cls) -> Optional[Type[Tool]]:
        return IfconfigFreebsd

    def get_interface_list(self) -> list[str]:
        # Use ip command to get interface list
        # Ifconfig is deprecated in Linux
        raise NotImplementedError()


class IfconfigFreebsd(Ifconfig):
    @property
    def command(self) -> str:
        return "ifconfig"

    def get_interface_list(self) -> list[str]:
        output = self.run(
            "-l",
            force_run=True,
            expected_exit_code=0,
            expected_exit_code_failure_message="Failed to get interface list",
        )
        return output.stdout.split()
