"""Offline checks for the DENUE roll-up (no network, no token)."""
from agents import denue as d


def row(rs, name, band, state, cls="466111", web=""):
    return {"Razon_social": rs, "Nombre": name, "Estrato": band, "Ubicacion": f"X,Y,{state}", "clase": cls,
            "Sitio_internet": web}


def test_norm_strips_company_type_and_accents():
    assert d.norm("Nueva Wal-Mart de México, S. de R.L. de C.V.") == "NUEVA WAL MART DE MEXICO"
    assert d.norm("GRUPO POSADAS SAB DE CV") == "GRUPO POSADAS"
    assert d.norm("IKANO RETAIL MEXICO SAPI DE CV") == "IKANO RETAIL MEXICO"


def test_roll_up_counts_branches_people_and_states():
    rows = [row("MUEBLES DICO SA DE CV", "DICO 1", "11 a 30 personas", "PUEBLA", web="WWW.DICO.COM.MX"),
            row("Muebles Dico, S.A. de C.V.", "DICO 2", "51 a 100 personas", "JALISCO"),
            row("", "2961 SALINAS Y ROCHA TEHUACAN", "0 a 5 personas", "PUEBLA"),
            row("", "MUEBLERIA", "0 a 5 personas", "PUEBLA")]          # generic name: not a company
    chains = {c["chain"]: c for c in d.roll_up(rows)}
    dico = chains["MUEBLES DICO"]
    assert dico["branches"] == 2 and dico["people_est"] == 95 and dico["n_states"] == 2
    assert dico["website"] == "www.dico.com.mx"
    assert "SALINAS Y ROCHA TEHUACAN" in chains and "MUEBLERIA" not in chains
    assert list(chains)[0] == "MUEBLES DICO"                                # biggest first
