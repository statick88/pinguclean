## Output de un Kali ya limpio:

<img width="1084" height="758" alt="image" src="https://github.com/user-attachments/assets/134a3f9b-369c-4b0f-b32d-8e3b4aefa2c1" />

### Cómo añadir al path del sistema este script de limpieza:

#### 1) Mueve el script a una ruta del sistema y dale permisos de root:

```bash
sudo install -o root -g root -m 750 /home/kali/Desktop/pinguclean.sh /usr/local/sbin/pinguclean.sh
```

#### 2) Añade la función al `.zshrc` (y al `.bashrc` si usas bash):

```bash
echo '
pingu() {
    sudo /usr/local/sbin/pinguclean.sh "$@"
}' >> ~/.zshrc && source ~/.zshrc

. ~/.zshrc
sudo chmod +x /usr/local/sbin/pinguclean.sh
```

#### 3) Ejecución:

```bash
sudo bash pinguclean.sh
```

<img width="929" height="486" alt="image" src="https://github.com/user-attachments/assets/0eb34e7f-a089-496f-8ff7-22a0cc9f0b04" />

