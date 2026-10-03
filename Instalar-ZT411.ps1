# =============================================================================
#  Instalador Zebra ZT411 (203 dpi)  (driver ZDesigner/Zebra)
#  Pacote de driver localizado em C:\ZDesigner
#  (copie TODO o conteudo da pasta do driver ZDesigner para C:\ZDesigner)
#
#  Uso local:        .\Instalar-ZT411.ps1
#  Uso via internet:  irm https://SEU-LINK/Instalar-ZT411.ps1 | iex
#
#  Nao exige PowerShell admin: o script roda normal e, no final, aparece um
#  unico prompt de UAC executando apenas as operacoes privilegiadas.
#
#  Etiqueta padrao configurada automaticamente: Etiqueta 100x150mm
# =============================================================================

# URL do pacote (zip) com os drivers, usado apenas quando os arquivos nao
# existirem em C:\ZDesigner (modo "irm | iex"). Preencha antes de publicar.
$DriverPackageUrl = 'https://github.com/canalqb/Zebra-Installer/releases/latest/download/ZDesigner.zip'

# ----------------------------------------------------------------------------
# Dados do modelo
# ----------------------------------------------------------------------------
$ModeloNome = 'Zebra ZT411'
$DriverNome = 'ZDesigner ZT411-203dpi ZPL'

# Etiqueta padrao (dimensoes em milesimos de milimetro)
$FormNome    = 'Etiqueta 100x150mm'
$FormLargura = 100000
$FormAltura  = 150000

# ----------------------------------------------------------------------------
# Funcoes auxiliares
# ----------------------------------------------------------------------------
function Ler-SimNao($Mensagem) {
    while ($true) {
        $r = Read-Host $Mensagem
        if ($r -match '^(?i:s|sim)$')  { return $true }
        if ($r -match '^(?i:n|nao|no)$'){ return $false }
        Write-Host 'Responda S ou N.' -ForegroundColor Yellow
    }
}

function Ler-Ip {
    while ($true) {
        $ip = (Read-Host 'Digite o endereco IP da impressora (ex.: 192.168.1.50)').Trim()
        $ok = $ip -match '^(\d{1,3}\.){3}\d{1,3}$' -and
              ($ip.Split('.') | ForEach-Object { [int]$_ -le 255 -and [int]$_ -ge 0 }) -notcontains $false
        if ($ok) { return $ip }
        Write-Host 'IP invalido. Tente novamente.' -ForegroundColor Yellow
    }
}

function Escolher-PortaTcp {
    $ip = Ler-Ip
    if (-not (Test-Connection -ComputerName $ip -Count 1 -Quiet)) {
        Write-Host "AVISO: nao houve resposta ao ping em $ip (pode ser normal se o firewall bloquear ICMP)." -ForegroundColor Yellow
    }
    return @{ Tipo = 'TCP'; Nome = "IP_$ip"; Endereco = $ip }
}

# Identifica quais portas USB do spooler pertencem a impressoras PnP
# atualmente CONECTADAS (via registro "USB Monitor" x dispositivos PnP).
function Get-PortasUsbConectadas {
    $ativas = @()
    $chave = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\USB Monitor\Ports'
    if (-not (Test-Path $chave)) { return $ativas }

    $conectadas = @{}
    foreach ($dev in (Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Printer'" -ErrorAction SilentlyContinue)) {
        $conectadas[$dev.DeviceID] = $dev.Name
    }

    foreach ($porta in (Get-ChildItem $chave -ErrorAction SilentlyContinue)) {
        $devId = (Get-ItemProperty -Path $porta.PSPath -ErrorAction SilentlyContinue).DeviceID
        if ($devId -and $conectadas.ContainsKey($devId)) {
            $ativas += @{ Porta = $porta.PSChildName; Dispositivo = $conectadas[$devId] }
        }
    }
    return $ativas
}

function Escolher-PortaUsb {
    $existentes = @(Get-PrinterPort -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'USB*' } | Select-Object -ExpandProperty Name)

    if ($existentes.Count -eq 1) {
        Write-Host "Porta USB encontrada automaticamente: $($existentes[0])"
        return @{ Tipo = 'USB'; Nome = $existentes[0] }
    }
    if ($existentes.Count -gt 1) {
        # tenta identificar a porta cuja impressora esta fisicamente conectada
        $conectadas = @(Get-PortasUsbConectadas | Where-Object { $existentes -contains $_.Porta })
        $zebra     = @($conectadas | Where-Object { $_.Dispositivo -like '*Zebra*' })
        $candidata = if ($zebra.Count -ge 1) { $zebra } else { $conectadas }

        if ($candidata.Count -eq 1) {
            Write-Host "Impressora detectada: $($candidata[0].Dispositivo)" -ForegroundColor Green
            Write-Host "Usando a porta $($candidata[0].Porta) (conectada fisicamente)." -ForegroundColor Green
            return @{ Tipo = 'USB'; Nome = $candidata[0].Porta }
        }
        if ($candidata.Count -gt 1) {
            Write-Host 'Mais de uma impressora USB conectada no momento:'
            for ($i = 0; $i -lt $candidata.Count; $i++) {
                Write-Host "  $($i + 1)) $($candidata[$i].Porta)  ($($candidata[$i].Dispositivo))"
            }
            while ($true) {
                $n = Read-Host 'Escolha o numero da porta em que a impressora esta conectada'
                if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $candidata.Count) {
                    return @{ Tipo = 'USB'; Nome = $candidata[[int]$n - 1].Porta }
                }
                Write-Host 'Opcao invalida.' -ForegroundColor Yellow
            }
        }

        Write-Host 'Foram encontradas varias portas USB (nenhuma com impressora conectada no momento):'
        for ($i = 0; $i -lt $existentes.Count; $i++) {
            Write-Host "  $($i + 1)) $($existentes[$i])"
        }
        while ($true) {
            $n = Read-Host 'Escolha o numero da porta em que a impressora esta conectada'
            if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $existentes.Count) {
                return @{ Tipo = 'USB'; Nome = $existentes[[int]$n - 1] }
            }
            Write-Host 'Opcao invalida.' -ForegroundColor Yellow
        }
    }

    # Nenhuma porta USB: aguardar a impressora ser ligada/conectada
    Write-Host ''
    Write-Host 'Nenhuma porta USB de impressora encontrada.' -ForegroundColor Yellow
    Write-Host 'Conecte a impressora via cabo USB e ligue-a agora.'
    Write-Host 'Aguardando a deteccao da impressora (ate 20 segundos)...' -ForegroundColor Cyan

    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $novas = @(Get-PrinterPort -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -like 'USB*' -and $existentes -notcontains $_.Name } |
                   Select-Object -ExpandProperty Name)
        if ($novas.Count -gt 0) {
            Write-Host "Impressora detectada na porta $($novas[0]) !" -ForegroundColor Green
            return @{ Tipo = 'USB'; Nome = $novas[0] }
        }
    }
    Write-Host 'Nenhuma porta USB detectada em 20 segundos; usando a porta USB001 como padrao.' -ForegroundColor Yellow
    return @{ Tipo = 'USB'; Nome = 'USB001' }
}

# ----------------------------------------------------------------------------
# Codigo C# (Win32) para criar o formulario de etiqueta e defini-lo como
# papel padrao da impressora via DEVMODE (codificado em Base64 abaixo).
# ----------------------------------------------------------------------------
$CsCodigo = @'
using System;
using System.Runtime.InteropServices;

namespace PrnForm {
  [StructLayout(LayoutKind.Sequential)]
  public struct SIZEL { public int cx; public int cy; }

  [StructLayout(LayoutKind.Sequential)]
  public struct RECTL { public int Left; public int Top; public int Right; public int Bottom; }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct FORM_INFO_1 {
    public int Flags;
    public string pName;
    public SIZEL Size;
    public RECTL ImageableArea;
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct PRINTER_DEFAULTS {
    public IntPtr pDatatype;
    public IntPtr pDevMode;
    public int DesiredAccess;
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct PRINTER_INFO_2 {
    public string pServerName;
    public string pPrinterName;
    public string pShareName;
    public string pPortName;
    public string pDriverName;
    public string pComment;
    public string pLocation;
    public IntPtr pDevMode;
    public string pSepFile;
    public string pPrintProcessor;
    public string pDataType;
    public string pParameters;
    public IntPtr pSecurityDescriptor;
    public int Attributes;
    public int Priority;
    public int DefaultPriority;
    public int StartTime;
    public int UntilTime;
    public int Status;
    public int cJobs;
    public int AveragePPM;
  }

  public class Util {
    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenPrinter(string pPrinterName, out IntPtr hPrinter, ref PRINTER_DEFAULTS pDefault);

    [DllImport("winspool.drv", SetLastError = true)]
    private static extern int ClosePrinter(IntPtr hPrinter);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool AddForm(IntPtr hPrinter, int Level, ref FORM_INFO_1 pForm);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int DocumentProperties(IntPtr hWnd, IntPtr hPrinter, string pDeviceName, IntPtr pDevModeOutput, IntPtr pDevModeInput, int fMode);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetPrinter(IntPtr hPrinter, int Level, IntPtr pPrinter, int cbBuf, out int pcbNeeded);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetPrinter(IntPtr hPrinter, int Level, IntPtr pPrinter, int Command);

    public static void Aplicar(string printerName, string formName, int larguraUm, int alturaUm) {
      PRINTER_DEFAULTS pd = new PRINTER_DEFAULTS();
      pd.DesiredAccess = 0x000F000C; // PRINTER_ALL_ACCESS
      IntPtr h;
      if (OpenPrinter(printerName, out h, ref pd) == IntPtr.Zero) {
        throw new Exception("OpenPrinter falhou (erro " + Marshal.GetLastWin32Error() + ")");
      }
      try {
        // 1) cria o formulario de etiqueta (se ainda nao existir)
        FORM_INFO_1 f = new FORM_INFO_1();
        f.Flags = 0;
        f.pName = formName;
        f.Size.cx = larguraUm;
        f.Size.cy = alturaUm;
        f.ImageableArea.Left = 0;
        f.ImageableArea.Top = 0;
        f.ImageableArea.Right = larguraUm;
        f.ImageableArea.Bottom = alturaUm;
        if (!AddForm(h, 1, ref f)) {
          int err = Marshal.GetLastWin32Error();
          if (err != 183) { // 183 = ja existe
            throw new Exception("AddForm falhou (erro " + err + ")");
          }
        }

        // 2) obtem o DEVMODE atual da impressora
        int need = DocumentProperties(IntPtr.Zero, h, printerName, IntPtr.Zero, IntPtr.Zero, 0);
        if (need <= 0) { throw new Exception("DocumentProperties falhou ao calcular o tamanho do DEVMODE"); }
        IntPtr dm = Marshal.AllocHGlobal(need);
        try {
          if (DocumentProperties(IntPtr.Zero, h, printerName, dm, IntPtr.Zero, 2 /* DM_OUT_BUFFER */) < 0) {
            throw new Exception("DocumentProperties falhou ao ler o DEVMODE");
          }

          // offsets do DEVMODE (estrutura de 32/64 bits com dmDeviceName wchar[32])
          //  72: dmFields (uint)
          //  78: dmPaperSize | 80: dmPaperLength | 82: dmPaperWidth (shorts, 0.1 mm)
          // 102: dmFormName (wchar[32])
          int campos = Marshal.ReadInt32(dm, 72);
          campos |= 2 | 4 | 8 | 0x10000; // DM_PAPERSIZE | DM_PAPERLENGTH | DM_PAPERWIDTH | DM_FORMNAME
          Marshal.WriteInt32(dm, 72, campos);
          Marshal.WriteInt16(dm, 78, (short)256);                    // DMPAPER_USER (tamanho personalizado)
          Marshal.WriteInt16(dm, 80, (short)(alturaUm / 100));        // altura em 0.1 mm
          Marshal.WriteInt16(dm, 82, (short)(larguraUm / 100));      // largura em 0.1 mm
          byte[] nome = System.Text.Encoding.Unicode.GetBytes(formName);
          if (nome.Length > 62) { Array.Resize(ref nome, 62); }
          Marshal.Copy(nome, 0, new IntPtr(dm.ToInt64() + 102), nome.Length);
          Marshal.WriteInt16(dm, 102 + 62, 0);                       // garante terminacao nula

          if (DocumentProperties(IntPtr.Zero, h, printerName, dm, dm, 3 /* DM_IN_BUFFER | DM_OUT_BUFFER */) < 0) {
            throw new Exception("DocumentProperties falhou ao validar o DEVMODE");
          }

          // 3) grava o DEVMODE como padrao da impressora (PRINTER_INFO_2)
          int need2 = 0;
          GetPrinter(h, 2, IntPtr.Zero, 0, out need2);
          if (need2 <= 0) { throw new Exception("GetPrinter falhou ao calcular o tamanho"); }
          IntPtr p2 = Marshal.AllocHGlobal(need2);
          try {
            int dummy = 0;
            if (!GetPrinter(h, 2, p2, need2, out dummy)) {
              throw new Exception("GetPrinter falhou (erro " + Marshal.GetLastWin32Error() + ")");
            }
            PRINTER_INFO_2 info = (PRINTER_INFO_2)Marshal.PtrToStructure(p2, typeof(PRINTER_INFO_2));
            info.pDevMode = dm;
            IntPtr p3 = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(PRINTER_INFO_2)));
            try {
              Marshal.StructureToPtr(info, p3, false);
              if (!SetPrinter(h, 2, p3, 0)) {
                throw new Exception("SetPrinter falhou (erro " + Marshal.GetLastWin32Error() + ")");
              }
            } finally { Marshal.FreeHGlobal(p3); }
          } finally { Marshal.FreeHGlobal(p2); }
        } finally { Marshal.FreeHGlobal(dm); }
      } finally { ClosePrinter(h); }
    }
  }
}
'@
$CsB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($CsCodigo))

# ----------------------------------------------------------------------------
# Payload que roda elevado (uma unica janela UAC).
# Placeholders: __NOME__, __PORTANOME__, __PORTATIPO__, __PORTAEND__,
#               __SUBSTITUIR__, __PKURL__, __CSB64__
# ----------------------------------------------------------------------------
$payload = @'
try {
  $ErrorActionPreference = 'Stop'
  $DriverRoot  = 'C:\ZDesigner'
  $PastaFonte  = '__SRCFOLDER__'
  # usa a pasta onde o instalador esta localizado se os drivers nao
  # estiverem em C:\ZDesigner
  if (-not (Test-Path "$DriverRoot\ZDesigner.inf") -and (Test-Path "$PastaFonte\ZDesigner.inf")) {
    $DriverRoot = $PastaFonte
  }
  $InfPath     = "$DriverRoot\ZDesigner.inf"
  $DriverPkgUrl = '__PKURL__'
  $driverNome  = 'ZDesigner ZT411-203dpi ZPL'
  $formNome    = 'Etiqueta 100x150mm'
  $formLargura = 100000
  $formAltura  = 150000
  $nome      = '__NOME__'
  $portaNome = '__PORTANOME__'
  $portaTipo = '__PORTATIPO__'
  $portaEnd  = '__PORTAEND__'

  # --- manutencao do spooler: para, limpa a fila e reinicia ---
  function Parar-Spooler {
    Write-Host "Parando o spooler de impressao (net stop spooler)..." -ForegroundColor Cyan
    $saida = & net.exe stop spooler 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Host "AVISO: net stop spooler falhou ($saida)" -ForegroundColor Yellow
    }
  }
  function Limpar-Spooler {
    $pasta = "$env:windir\System32\spool\PRINTERS"
    if (Test-Path $pasta) {
      Write-Host "Limpando conteudo de $pasta ..." -ForegroundColor Cyan
      Get-ChildItem -Path $pasta -Force -ErrorAction SilentlyContinue |
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    } else {
      Write-Host "Pasta $pasta nao existe; nada a limpar."
    }
  }
  function Iniciar-Spooler {
    Write-Host "Iniciando o spooler de impressao (net start spooler)..." -ForegroundColor Cyan
    $saida = & net.exe start spooler 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Host "AVISO: net start spooler falhou ($saida)" -ForegroundColor Yellow
    }
  }

  Parar-Spooler
  Limpar-Spooler
  Iniciar-Spooler

  # --- garante os drivers em C:\ZDesigner ---
  if (-not (Test-Path $InfPath)) {
    if ($DriverPkgUrl -like 'COLE_AQUI*' -or [string]::IsNullOrWhiteSpace($DriverPkgUrl)) {
      Write-Host 'ERRO: drivers nao encontrados em C:\ZDesigner e sem URL de download configurada.' -ForegroundColor Red
    } else {
      Write-Host 'Baixando pacote de drivers...' -ForegroundColor Cyan
      $zip = Join-Path $env:TEMP 'ZDesignerDrivers.zip'
      Invoke-RestMethod -Uri $DriverPkgUrl -OutFile $zip
      Write-Host 'Extraindo drivers...'
      Expand-Archive -Path $zip -DestinationPath $DriverRoot -Force
      if (-not (Test-Path $InfPath)) {
        $inf = Get-ChildItem -Path $DriverRoot -Recurse -Filter 'ZDesigner.inf' | Select-Object -First 1
        if ($inf) {
          $base = Split-Path (Split-Path $inf.FullName)
          if ($base -ne $DriverRoot) { Get-ChildItem $base | Move-Item -Destination $DriverRoot -Force }
        }
      }
    }
  }

  if (-not (Test-Path $InfPath)) {
    Write-Host 'ERRO: ZDesigner.inf nao encontrado em C:\ZDesigner.' -ForegroundColor Red
  } else {

    # --- instala o driver ---
    Write-Host "Instalando o driver (pode demorar alguns minutos)..." -ForegroundColor Cyan
    if (-not (Get-PrinterDriver -Name $driverNome -ErrorAction SilentlyContinue)) {
      # 1) registra o pacote no driver store do Windows
      $saida = & pnputil.exe /add-driver $InfPath /install 2>&1
      if ($LASTEXITCODE -ne 0) {
        Write-Host "AVISO: pnputil retornou codigo ${LASTEXITCODE}:" -ForegroundColor Yellow
        $saida | ForEach-Object { Write-Host "  $_" }
      }
    }
    # 2) registra o driver no spooler de impressao (pnputil so faz isso
    #    para dispositivos PnP presentes; driver v3 legacy precisa disto).
    #    O Add-PrinterDriver exige o INF JA publicado no store (oem##.inf),
    #    entao localizamos pelo catalogo ZDesignerNTamd64.CAT dentro do INF.
    if (-not (Get-PrinterDriver -Name $driverNome -ErrorAction SilentlyContinue)) {
      try {
        $infStore = (Get-ChildItem "$env:windir\INF\oem*.inf" -ErrorAction SilentlyContinue |
                      Where-Object { (Get-Content $_.FullName -TotalCount 40 -ErrorAction SilentlyContinue) -match "ZDesignerNTamd64\.CAT" } |
                      Select-Object -First 1).FullName
        if (-not $infStore) { $infStore = $InfPath }
        Add-PrinterDriver -Name $driverNome -InfPath $infStore -ErrorAction Stop
      } catch {
        Write-Host "AVISO: Add-PrinterDriver falhou: $($_.Exception.Message)" -ForegroundColor Yellow
      }
    }
    if (-not (Get-PrinterDriver -Name $driverNome -ErrorAction SilentlyContinue)) {
      Write-Host "ERRO: o driver $driverNome nao ficou disponivel apos a instalacao." -ForegroundColor Red
      Write-Host "Drivers ZDesigner atualmente disponiveis:" -ForegroundColor Yellow
      Get-PrinterDriver | Where-Object { $_.Name -like "*ZDesigner*" } | ForEach-Object { Write-Host "  - $($_.Name)" }
    } else {

      # --- cria a porta TCP/IP ou USB se necessario ---
      if (Get-PrinterPort -Name $portaNome -ErrorAction SilentlyContinue) {
        Write-Host "Porta $portaNome ja existe; reutilizando."
      } else {
        if ($portaTipo -eq "TCP") {
          Write-Host "Criando porta TCP/IP $portaNome..."
          Add-PrinterPort -Name $portaNome -PrinterHostAddress $portaEnd
        } else {
          Write-Host "Criando porta local $portaNome..."
          Add-PrinterPort -Name $portaNome
        }
      }

      # --- cria a impressora ---
      if (Get-Printer -Name $nome -ErrorAction SilentlyContinue) {
        if (__SUBSTITUIR__) { Remove-Printer -Name $nome }
        else {
          Write-Host 'AVISO: ja existe uma impressora com este nome; nada foi alterado.' -ForegroundColor Yellow
        }
      }
      if (-not (Get-Printer -Name $nome -ErrorAction SilentlyContinue)) {
        Add-Printer -Name $nome -DriverName $driverNome -PortName $portaNome

        # --- define a etiqueta padrao (formulario personalizado via DEVMODE) ---
        Write-Host "Configurando etiqueta padrao: $formNome ..." -ForegroundColor Cyan
        $cs = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__CSB64__'))
        Add-Type -TypeDefinition $cs
        $okEtiqueta = $false
        $ultimoErro = $null
        # ate 3 tentativas: logo apos criar a impressora o spooler pode
        # responder erro temporario (ex.: erro 80) na criacao do formulario
        for ($tentativa = 1; $tentativa -le 3 -and -not $okEtiqueta; $tentativa++) {
          try {
            [PrnForm.Util]::Aplicar($nome, $formNome, $formLargura, $formAltura)
            $okEtiqueta = $true
          } catch {
            $ultimoErro = $_.Exception.Message
            if ($tentativa -lt 3) {
              Write-Host "Tentativa $tentativa falhou ($ultimoErro). Repetindo em 5 segundos..." -ForegroundColor Yellow
              Start-Sleep -Seconds 5
            }
          }
        }
        if ($okEtiqueta) {
          Write-Host "Etiqueta padrao definida: $formNome." -ForegroundColor Green
          Write-Host 'Dica: se for a primeira instalacao, faca a calibracao de midia na impressora.' -ForegroundColor Yellow
        } else {
          Write-Host "AVISO: nao foi possivel definir a etiqueta padrao automaticamente ($ultimoErro)." -ForegroundColor Yellow
          Write-Host "Defina manualmente em: Preferencias de impressao > Papel/Formato > $formNome." -ForegroundColor Yellow
        }

        Write-Host ''
        Write-Host '============================================================' -ForegroundColor Green
        Write-Host ' Impressora instalada com sucesso!'
        Write-Host " Nome  : $nome"
        Write-Host " Driver: $driverNome"
        Write-Host " Porta : $portaNome"
        Write-Host " Etiqueta padrao: $formNome"
        Write-Host '============================================================' -ForegroundColor Green

        # --- pagina de teste opcional ---
        $enviar = $null
        while ($enviar -notmatch '^(?i:s|sim|n|nao|no)$') {
          $enviar = Read-Host 'Enviar pagina de teste? (S/N)'
        }
        if ($enviar -match '^(?i:s|sim)$') {
          Write-Host 'Enviando pagina de teste...' -ForegroundColor Cyan
          Start-Sleep -Seconds 2
          $null = & rundll32.exe printui.dll,PrintUIEntry /k /n "$nome" 2>&1
          Write-Host 'Pagina de teste enviada.'
        }
      }
    }
  }

  # --- ciclo final: aguarda 10s e reinicia o spooler limpo ---
  Write-Host "Aguardando 10 segundos antes de reiniciar o spooler..." -ForegroundColor Cyan
  Start-Sleep -Seconds 10
  Parar-Spooler
  Limpar-Spooler
  Iniciar-Spooler
} catch {
  Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
} finally {
  Write-Host ''
  Read-Host 'Pressione Enter para fechar' | Out-Null
}
'@

# ----------------------------------------------------------------------------
# Menu principal (roda SEM privilegios; so a instalacao final e elevada)
# ----------------------------------------------------------------------------
while ($true) {
Write-Host ''
Write-Host '============================================================'
Write-Host "   Instalador Zebra ZT411 (203 dpi)"
Write-Host '============================================================'
Write-Host ''
Write-Host "Impressora: $ModeloNome"
Write-Host "Driver    : $DriverNome"
Write-Host "Etiqueta  : $FormNome (padrao)"
Write-Host ''
Write-Host 'Qual o tipo de conexao?'
Write-Host '  1) Rede (TCP/IP - informe o IP da impressora)'
Write-Host '  2) USB (deteccao automatica da porta)'
$opPorta = Read-Host 'Opcao'
while ($opPorta -ne '1' -and $opPorta -ne '2') {
    Write-Host 'Opcao invalida. Tente novamente.' -ForegroundColor Yellow
    $opPorta = Read-Host 'Opcao'
}

if ($opPorta -eq '1') {
    $porta = Escolher-PortaTcp
} else {
    $porta = Escolher-PortaUsb
}
if (-not $porta) { exit 1 }

$sufixoPorta = if ($porta.Tipo -eq 'TCP') { $porta.Endereco } else { $porta.Nome }

$nomeImpressora = (Read-Host "Nome da impressora [padrao: $ModeloNome 203dpi $sufixoPorta]").Trim()
if ([string]::IsNullOrWhiteSpace($nomeImpressora)) { $nomeImpressora = "$ModeloNome 203dpi $sufixoPorta" }

$substituir = $true
if (Get-Printer -Name $nomeImpressora -ErrorAction SilentlyContinue) {
    $substituir = Ler-SimNao "Ja existe uma impressora chamada `"$nomeImpressora`". Substituir? (S/N)"
    if (-not $substituir) {
        Write-Host 'Instalacao cancelada.' -ForegroundColor Yellow
        exit 0
    }
}

# ----------------------------------------------------------------------------
# Instalacao elevada (um unico prompt de UAC)
# ----------------------------------------------------------------------------
Write-Host ''
Write-Host 'Abrindo a instalacao com privilegios de Administrador...' -ForegroundColor Cyan
Write-Host 'Confirme a janela do UAC para continuar.' -ForegroundColor Yellow

$pastaOrigem = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$payloadFinal = $payload.Replace('__PKURL__', $DriverPackageUrl)
$payloadFinal = $payloadFinal.Replace('__SRCFOLDER__', $pastaOrigem)
$payloadFinal = $payloadFinal.Replace('__NOME__', $nomeImpressora)
$payloadFinal = $payloadFinal.Replace('__PORTANOME__', $porta.Nome)
$payloadFinal = $payloadFinal.Replace('__PORTATIPO__', $porta.Tipo)
$payloadFinal = $payloadFinal.Replace('__PORTAEND__', $porta.Endereco)
$payloadFinal = $payloadFinal.Replace('__SUBSTITUIR__', "$substituir")
$payloadFinal = $payloadFinal.Replace('__CSB64__', $CsB64)

# O payload e grande (codigo C# embutido em Base64), entao em vez de
# EncodedCommand (limite de ~32k caracteres na linha de comando), gravamos
# o payload em um arquivo .ps1 temporario e elevamos com -File.
$arquivoPayload = Join-Path $env:TEMP ("Instalar-Zebra-elevado-" + [guid]::NewGuid().ToString('N') + ".ps1")
[IO.File]::WriteAllText($arquivoPayload, $payloadFinal, [Text.Encoding]::Unicode)

$processo = Start-Process "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -PassThru -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File', $arquivoPayload
)

if (-not $processo) {
    Write-Host 'ERRO: a elevacao foi cancelada; a instalacao nao foi realizada.' -ForegroundColor Red
    exit 1
}

$processo.WaitForExit()
Remove-Item -Path $arquivoPayload -Force -ErrorAction SilentlyContinue
if ($processo.ExitCode -eq 0) {
    Write-Host 'Processo de instalacao finalizado. Verifique a janela elevada para o resultado.' -ForegroundColor Green
} else {
    Write-Host 'O processo elevado encerrou. Verifique a janela de instalacao para o resultado.' -ForegroundColor Yellow
}

$instalarNova = Ler-SimNao 'Deseja instalar uma nova impressora? (S/N)'
if (-not $instalarNova) {
    Write-Host 'Encerrando o instalador.' -ForegroundColor Cyan
    exit
}
cls
}
