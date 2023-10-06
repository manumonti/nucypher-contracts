import json
import os
from collections import defaultdict
from enum import Enum
from pathlib import Path
from typing import Dict, List, NamedTuple, Optional

from ape.contracts import ContractInstance
from eth_typing import ChecksumAddress
from eth_utils import to_checksum_address
from web3.types import ABI

from deployment.utils import validate_config, get_contract_container, _load_json

ChainId = int
ContractName = str


class RegistryEntry(NamedTuple):
    """Represents a single entry in a nucypher-style contract registry."""
    chain_id: ChainId
    name: ContractName
    address: ChecksumAddress
    abi: ABI
    tx_hash: str
    block_number: int
    deployer: str


def _get_abi(contract_instance: ContractInstance) -> ABI:
    """Returns the ABI of a contract instance."""
    contract_abi = list()
    for entry in contract_instance.contract_type.abi:
        contract_abi.append(entry.dict())
    return contract_abi


def _get_name(
    contract_instance: ContractInstance, registry_names: Dict[ContractName, ContractName]
) -> ContractName:
    """
    Returns the optionally remapped registry name of a contract instance.
    If the contract instance is not remapped, the real contract name is returned.
    """
    real_contract_name = contract_instance.contract_type.name
    contract_name = registry_names.get(
        real_contract_name,  # look up name in registry_names
        real_contract_name,  # default to the real contract name
    )
    return contract_name


def _get_entry(
    contract_instance: ContractInstance, registry_names: Dict[ContractName, ContractName]
) -> RegistryEntry:
    contract_abi = _get_abi(contract_instance)
    contract_name = _get_name(contract_instance=contract_instance, registry_names=registry_names)
    receipt = contract_instance.receipt
    entry = RegistryEntry(
        name=contract_name,
        address=to_checksum_address(contract_instance.address),
        abi=contract_abi,
        chain_id=receipt.chain_id,
        tx_hash=receipt.txn_hash,
        block_number=receipt.block_number,
        deployer=receipt.transaction.sender
    )
    return entry


def _get_entries(
        contract_instances: List[ContractInstance],
        registry_names: Dict[ContractName, ContractName]
) -> List[RegistryEntry]:
    """Returns a list of contract entries from a list of contract instances."""
    entries = list()
    for contract_instance in contract_instances:
        entry = _get_entry(
            contract_instance=contract_instance,
            registry_names=registry_names
        )
        entries.append(entry)
    return entries


def read_registry(filepath: Path) -> List[RegistryEntry]:
    with open(filepath, "r") as file:
        data = json.load(file)
    registry_entries = list()
    for chain_id, entries in data.items():
        for contract_name, artifacts in entries.items():
            registry_entry = RegistryEntry(
                chain_id=int(chain_id),
                name=contract_name,
                address=artifacts['address'],
                abi=artifacts['abi'],
                tx_hash=artifacts['tx_hash'],
                block_number=artifacts['block_number'],
                deployer=artifacts['deployer']
            )
            registry_entries.append(registry_entry)
    return registry_entries


def write_registry(entries: List[RegistryEntry], filepath: Path) -> Path:
    """Writes a nucypher-style contract registry to a file."""

    if not entries:
        print("No entries provided.")
        return filepath

    data = defaultdict(dict)
    for entry in entries:
        data[entry.chain_id][entry.name] = {
            "address": entry.address,
            "abi": entry.abi,
            "tx_hash": entry.tx_hash,
            "block_number": entry.block_number,
            "deployer": entry.deployer,
        }

    # Create the parent directory if it does not exist
    filepath.parent.mkdir(parents=True, exist_ok=True)

    # If the file already exists, attempt to merge the data, if not create a new file
    if filepath.exists():
        print(f"Updating existing registry at {filepath}.")
        existing_data = _load_json(filepath)

        if any(chain_id in existing_data for chain_id in data):
            filepath = filepath.with_suffix('.unmerged.json')
            print("Cannot merge registries with overlapping chain IDs.\n"
                  f"Writing to {filepath} to avoid overwriting existing data.")
        else:
            existing_data.update(data)
            data = existing_data
    else:
        print(f"Creating new registry at {filepath}.")

    with open(filepath, "w") as file:
        json.dump(data, file, indent=4)

    return filepath


class ConflictResolution(Enum):
    USE_1 = 1
    USE_2 = 2


def _select_conflict_resolution(
    registry_1_entry, registry_1_filepath, registry_2_entry, registry_2_filepath
) -> ConflictResolution:
    print(f"\n! Conflict detected for {registry_1_entry.name}:")
    print(
        f"[1]: {registry_1_entry.name} at {registry_1_entry.address} "
        f"for {registry_1_filepath}"
    )
    print(
        f"[2]: {registry_2_entry.name} at {registry_2_entry.address} "
        f"for {registry_2_filepath}"
    )
    print("[A]: Abort merge")

    valid_str_answers = [
        str(ConflictResolution.USE_1.value),
        str(ConflictResolution.USE_2.value),
        "A",
    ]
    answer = None
    while answer not in valid_str_answers:
        answer = input(f"Merge resolution, {valid_str_answers}? ")

    if answer == "A":
        print("Merge Aborted!")
        exit(-1)
    return ConflictResolution(int(answer))


def registry_from_ape_deployments(
    deployments: List[ContractInstance],
    output_filepath: Path,
    registry_names: Optional[Dict[ContractName, ContractName]] = None,
) -> Path:
    """Creates a nucypher-style contract registry from ape deployments API."""
    registry_names = registry_names or dict()
    entries = _get_entries(contract_instances=deployments, registry_names=registry_names)
    output_filepath = write_registry(entries=entries, filepath=output_filepath)
    print(f"(i) Registry written to {output_filepath}!")
    return output_filepath


def merge_registries(
        registry_1_filepath: Path,
        registry_2_filepath: Path,
        output_filepath: Path,
        deprecated_contracts: Optional[List[ContractName]] = None,
) -> Path:
    """Merges two nucypher-style contract registries created from ape deployments API."""
    validate_config(registry_filepath=output_filepath)

    # If no deprecated contracts are specified, use an empty list
    deprecated_contracts = deprecated_contracts or []

    # Read the registries, excluding deprecated contracts
    reg1 = {e.name: e for e in read_registry(registry_1_filepath) if e.name not in deprecated_contracts}
    reg2 = {e.name: e for e in read_registry(registry_2_filepath) if e.name not in deprecated_contracts}

    merged: List[RegistryEntry] = list()

    # Iterate over all unique contract names across both registries
    conflicts, contracts = set(reg1) & set(reg2), set(reg1) | set(reg2)
    for name in contracts:
        entry_1, entry_2 = reg1.get(name), reg2.get(name)
        conflict = name in conflicts and entry_1.chain_id == entry_2.chain_id
        if conflict:
            resolution = _select_conflict_resolution(
                registry_1_entry=entry_1,
                registry_2_entry=entry_2,
                registry_1_filepath=registry_1_filepath,
                registry_2_filepath=registry_2_filepath
            )
            selected_entry = entry_1 if resolution == ConflictResolution.USE_1 else entry_2
        else:
            selected_entry = entry_1 or entry_2

        # commit the selected entry
        merged.append(selected_entry)

    # Write the merged registry to the specified output file path
    write_registry(entries=merged, filepath=output_filepath)
    print(f"Merged registry output to {output_filepath}")
    return output_filepath


def contracts_from_registry(filepath: Path) -> Dict[str, ContractInstance]:
    """Returns a dictionary of contract instances from a nucypher-style contract registry."""
    registry_entries = read_registry(filepath=filepath)
    deployments = dict()
    for registry_entry in registry_entries:
        contract_type = registry_entry.name
        contract_container = get_contract_container(contract_type)
        contract_instance = contract_container.at(registry_entry.address)
        deployments[contract_type] = contract_instance
    return deployments
