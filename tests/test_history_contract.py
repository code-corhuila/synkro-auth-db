import pathlib
import tomllib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DOMAIN = ROOT.name.removeprefix('synkro-').removesuffix('-db')

class HistoryContract(unittest.TestCase):
    def test_domain_owns_its_history(self):
        config = tomllib.loads((ROOT / 'flyway.toml').read_text())['flyway']
        self.assertEqual(config.get('schemas'), [DOMAIN + '_schema'])
        self.assertEqual(config.get('defaultSchema'), DOMAIN + '_schema')
    def test_ci_drops_history_before_schema_rollbacks(self):
        workflow = (ROOT / '.github/workflows/db-ci.yml').read_text()
        drop = workflow.index('DROP TABLE IF EXISTS ' + DOMAIN + '_schema.flyway_schema_history')
        rollback = workflow.index("find 05_rollbacks -name 'U*.sql'")
        self.assertLess(drop, rollback)

if __name__ == '__main__':
    unittest.main()
