import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_gateway_descriptor as verifier


class GatewayDescriptorVerifierTest(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = {
            "chainId": 84532,
            "contracts": {
                "proxies": [f"0x{index:040x}" for index in range(1, 10)],
            },
            "external": {
                "identityRegistry": {"proxy": "0x" + "11" * 20},
                "sanctionsOracle": "0x" + "12" * 20,
                "usdc": {
                    "address": "0x" + "13" * 20,
                    "decimals": 6,
                    "name": "USDC",
                    "version": "2",
                    "domainSeparator": "0x" + "14" * 32,
                },
                "eas": "0x" + "15" * 20,
            },
            "schemas": {
                "confirmation": {"uid": "0x" + "16" * 32},
                "outcome": {"uid": "0x" + "17" * 32},
            },
        }
        self.descriptor = verifier.expected_descriptor(self.manifest)

    def test_accepts_exact_descriptor_with_checksum_case_difference(self) -> None:
        descriptor = copy.deepcopy(self.descriptor)
        descriptor["contracts"]["usdc"] = descriptor["contracts"]["usdc"].upper().replace("0X", "0x")
        verifier.verify(self.manifest, descriptor)

    def test_rejects_every_bound_section_mismatch(self) -> None:
        mutations = (
            ("chainId", lambda value: value.__setitem__("chainId", 8453)),
            (
                "contracts",
                lambda value: value["contracts"].__setitem__("paymentRouter", "0x" + "99" * 20),
            ),
            (
                "schemas",
                lambda value: value["schemas"].__setitem__("easOutcome", "0x" + "99" * 32),
            ),
            (
                "usdcDomain",
                lambda value: value["usdcDomain"].__setitem__("name", "USD Coin"),
            ),
        )
        for name, mutate in mutations:
            with self.subTest(name=name):
                changed = copy.deepcopy(self.descriptor)
                mutate(changed)
                with self.assertRaisesRegex(ValueError, "does not match"):
                    verifier.verify(self.manifest, changed)


if __name__ == "__main__":
    unittest.main()
